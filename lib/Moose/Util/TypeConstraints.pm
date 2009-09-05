
package Moose::Util::TypeConstraints;

use Carp ();
use List::MoreUtils qw( all any );
use Scalar::Util qw( blessed reftype );
use Moose::Exporter;

our $VERSION = '0.89_01';
$VERSION = eval $VERSION;
our $AUTHORITY = 'cpan:STEVAN';

## --------------------------------------------------------
# Prototyped subs must be predeclared because we have a
# circular dependency with Moose::Meta::Attribute et. al.
# so in case of us being use'd first the predeclaration
# ensures the prototypes are in scope when consumers are
# compiled.

# dah sugah!
sub where (&);
sub via (&);
sub message (&);
sub optimize_as (&);

## --------------------------------------------------------

use Moose::Meta::TypeConstraint;
use Moose::Meta::TypeConstraint::Union;
use Moose::Meta::TypeConstraint::Parameterized;
use Moose::Meta::TypeConstraint::Parameterizable;
use Moose::Meta::TypeConstraint::Class;
use Moose::Meta::TypeConstraint::Role;
use Moose::Meta::TypeConstraint::Enum;
use Moose::Meta::TypeConstraint::DuckType;
use Moose::Meta::TypeCoercion;
use Moose::Meta::TypeCoercion::Union;
use Moose::Meta::TypeConstraint::Registry;
use Moose::Util::TypeConstraints::OptimizedConstraints;

Moose::Exporter->setup_import_methods(
    as_is => [
        qw(
            type subtype class_type role_type maybe_type duck_type
            as where message optimize_as
            coerce from via
            enum
            find_type_constraint
            register_type_constraint )
    ],
    _export_to_main => 1,
);

## --------------------------------------------------------
## type registry and some useful functions for it
## --------------------------------------------------------

my $REGISTRY = Moose::Meta::TypeConstraint::Registry->new;

sub get_type_constraint_registry {$REGISTRY}
sub list_all_type_constraints    { keys %{ $REGISTRY->type_constraints } }

sub export_type_constraints_as_functions {
    my $pkg = caller();
    no strict 'refs';
    foreach my $constraint ( keys %{ $REGISTRY->type_constraints } ) {
        my $tc = $REGISTRY->get_type_constraint($constraint)
            ->_compiled_type_constraint;
        *{"${pkg}::${constraint}"}
            = sub { $tc->( $_[0] ) ? 1 : undef };    # the undef is for compat
    }
}

sub create_type_constraint_union {
    my @type_constraint_names;

    if ( scalar @_ == 1 && _detect_type_constraint_union( $_[0] ) ) {
        @type_constraint_names = _parse_type_constraint_union( $_[0] );
    }
    else {
        @type_constraint_names = @_;
    }

    ( scalar @type_constraint_names >= 2 )
        || __PACKAGE__->_throw_error(
        "You must pass in at least 2 type names to make a union");

    my @type_constraints = map {
        find_or_parse_type_constraint($_)
            || __PACKAGE__->_throw_error(
            "Could not locate type constraint ($_) for the union");
    } @type_constraint_names;

    return Moose::Meta::TypeConstraint::Union->new(
        type_constraints => \@type_constraints );
}

sub create_parameterized_type_constraint {
    my $type_constraint_name = shift;
    my ( $base_type, $type_parameter )
        = _parse_parameterized_type_constraint($type_constraint_name);

    ( defined $base_type && defined $type_parameter )
        || __PACKAGE__->_throw_error(
        "Could not parse type name ($type_constraint_name) correctly");

    if ( $REGISTRY->has_type_constraint($base_type) ) {
        my $base_type_tc = $REGISTRY->get_type_constraint($base_type);
        return _create_parameterized_type_constraint(
            $base_type_tc,
            $type_parameter
        );
    }
    else {
        __PACKAGE__->_throw_error(
            "Could not locate the base type ($base_type)");
    }
}

sub _create_parameterized_type_constraint {
    my ( $base_type_tc, $type_parameter ) = @_;
    if ( $base_type_tc->can('parameterize') ) {
        return $base_type_tc->parameterize($type_parameter);
    }
    else {
        return Moose::Meta::TypeConstraint::Parameterized->new(
            name   => $base_type_tc->name . '[' . $type_parameter . ']',
            parent => $base_type_tc,
            type_parameter =>
                find_or_create_isa_type_constraint($type_parameter),
        );
    }
}

#should we also support optimized checks?
sub create_class_type_constraint {
    my ( $class, $options ) = @_;

# too early for this check
#find_type_constraint("ClassName")->check($class)
#    || __PACKAGE__->_throw_error("Can't create a class type constraint because '$class' is not a class name");

    my %options = (
        class => $class,
        name  => $class,
        %{ $options || {} },
    );

    $options{name} ||= "__ANON__";

    Moose::Meta::TypeConstraint::Class->new(%options);
}

sub create_role_type_constraint {
    my ( $role, $options ) = @_;

# too early for this check
#find_type_constraint("ClassName")->check($class)
#    || __PACKAGE__->_throw_error("Can't create a class type constraint because '$class' is not a class name");

    my %options = (
        role => $role,
        name => $role,
        %{ $options || {} },
    );

    $options{name} ||= "__ANON__";

    Moose::Meta::TypeConstraint::Role->new(%options);
}

sub find_or_create_type_constraint {
    my ( $type_constraint_name, $options_for_anon_type ) = @_;

    if ( my $constraint
        = find_or_parse_type_constraint($type_constraint_name) ) {
        return $constraint;
    }
    elsif ( defined $options_for_anon_type ) {

        # NOTE:
        # if there is no $options_for_anon_type
        # specified, then we assume they don't
        # want to create one, and return nothing.

        # otherwise assume that we should create
        # an ANON type with the $options_for_anon_type
        # options which can be passed in. It should
        # be noted that these don't get registered
        # so we need to return it.
        # - SL
        return Moose::Meta::TypeConstraint->new(
            name => '__ANON__',
            %{$options_for_anon_type}
        );
    }

    return;
}

sub find_or_create_isa_type_constraint {
    my $type_constraint_name = shift;
    find_or_parse_type_constraint($type_constraint_name)
        || create_class_type_constraint($type_constraint_name);
}

sub find_or_create_does_type_constraint {
    my $type_constraint_name = shift;
    find_or_parse_type_constraint($type_constraint_name)
        || create_role_type_constraint($type_constraint_name);
}

sub find_or_parse_type_constraint {
    my $type_constraint_name = normalize_type_constraint_name(shift);
    my $constraint;

    if ( $constraint = find_type_constraint($type_constraint_name) ) {
        return $constraint;
    }
    elsif ( _detect_type_constraint_union($type_constraint_name) ) {
        $constraint = create_type_constraint_union($type_constraint_name);
    }
    elsif ( _detect_parameterized_type_constraint($type_constraint_name) ) {
        $constraint
            = create_parameterized_type_constraint($type_constraint_name);
    }
    else {
        return;
    }

    $REGISTRY->add_type_constraint($constraint);
    return $constraint;
}

sub normalize_type_constraint_name {
    my $type_constraint_name = shift;
    $type_constraint_name =~ s/\s//g;
    return $type_constraint_name;
}

sub _confess {
    my $error = shift;

    local $Carp::CarpLevel = $Carp::CarpLevel + 1;
    Carp::confess($error);
}

## --------------------------------------------------------
## exported functions ...
## --------------------------------------------------------

sub find_type_constraint {
    my $type = shift;

    if ( blessed $type and $type->isa("Moose::Meta::TypeConstraint") ) {
        return $type;
    }
    else {
        return unless $REGISTRY->has_type_constraint($type);
        return $REGISTRY->get_type_constraint($type);
    }
}

sub register_type_constraint {
    my $constraint = shift;
    __PACKAGE__->_throw_error("can't register an unnamed type constraint")
        unless defined $constraint->name;
    $REGISTRY->add_type_constraint($constraint);
    return $constraint;
}

# type constructors

sub type {

    # back-compat version, called without sugar
    if ( !any { ( reftype($_) || '' ) eq 'HASH' } @_ ) {
        return _create_type_constraint( $_[0], undef, $_[1] );
    }

    my $name = shift;

    my %p = map { %{$_} } @_;

    return _create_type_constraint(
        $name, undef, $p{where}, $p{message},
        $p{optimize_as}
    );
}

sub subtype {

    # crazy back-compat code for being called without sugar ...
    #
    # subtype 'Parent', sub { where };
    if ( scalar @_ == 2 && ( reftype( $_[1] ) || '' ) eq 'CODE' ) {
        return _create_type_constraint( undef, @_ );
    }

    # subtype 'Parent', sub { where }, sub { message };
    # subtype 'Parent', sub { where }, sub { message }, sub { optimized };
    if ( scalar @_ >= 3 && all { ( reftype($_) || '' ) eq 'CODE' }
        @_[ 1 .. $#_ ] ) {
        return _create_type_constraint( undef, @_ );
    }

    # subtype 'Name', 'Parent', ...
    if ( scalar @_ >= 2 && all { !ref } @_[ 0, 1 ] ) {
        return _create_type_constraint(@_);
    }

    if ( @_ == 1 && !ref $_[0] ) {
        __PACKAGE__->_throw_error(
            'A subtype cannot consist solely of a name, it must have a parent'
        );
    }

    # The blessed check is mostly to accommodate MooseX::Types, which
    # uses an object which overloads stringification as a type name.
    my $name = ref $_[0] && !blessed $_[0] ? undef : shift;

    my %p = map { %{$_} } @_;

    # subtype Str => where { ... };
    if ( !exists $p{as} ) {
        $p{as} = $name;
        $name = undef;
    }

    return _create_type_constraint(
        $name, $p{as}, $p{where}, $p{message},
        $p{optimize_as}
    );
}

sub class_type {
    register_type_constraint(
        create_class_type_constraint(
            $_[0],
            ( defined( $_[1] ) ? $_[1] : () ),
        )
    );
}

sub role_type ($;$) {
    register_type_constraint(
        create_role_type_constraint(
            $_[0],
            ( defined( $_[1] ) ? $_[1] : () ),
        )
    );
}

sub maybe_type {
    my ($type_parameter) = @_;

    register_type_constraint(
        $REGISTRY->get_type_constraint('Maybe')->parameterize($type_parameter)
    );
}

sub duck_type {
    my ( $type_name, @methods ) = @_;
    if ( ref $type_name eq 'ARRAY' && !@methods ) {
        @methods   = @$type_name;
        $type_name = undef;
    }

    register_type_constraint(
        create_duck_type_constraint(
            $type_name,
            \@methods,
        )
    );
}

sub coerce {
    my ( $type_name, @coercion_map ) = @_;
    _install_type_coercions( $type_name, \@coercion_map );
}

# The trick of returning @_ lets us avoid having to specify a
# prototype. Perl will parse this:
#
# subtype 'Foo'
#     => as 'Str'
#     => where { ... }
#
# as this:
#
# subtype( 'Foo', as( 'Str', where { ... } ) );
#
# If as() returns all it's extra arguments, this just works, and
# preserves backwards compatibility.
sub as { { as => shift }, @_ }
sub where (&)       { { where       => $_[0] } }
sub message (&)     { { message     => $_[0] } }
sub optimize_as (&) { { optimize_as => $_[0] } }

sub from    {@_}
sub via (&) { $_[0] }

sub enum {
    my ( $type_name, @values ) = @_;

    # NOTE:
    # if only an array-ref is passed then
    # you get an anon-enum
    # - SL
    if ( ref $type_name eq 'ARRAY' && !@values ) {
        @values    = @$type_name;
        $type_name = undef;
    }
    ( scalar @values >= 2 )
        || __PACKAGE__->_throw_error(
        "You must have at least two values to enumerate through");
    my %valid = map { $_ => 1 } @values;

    register_type_constraint(
        create_enum_type_constraint(
            $type_name,
            \@values,
        )
    );
}

sub create_enum_type_constraint {
    my ( $type_name, $values ) = @_;

    Moose::Meta::TypeConstraint::Enum->new(
        name => $type_name || '__ANON__',
        values => $values,
    );
}

sub create_duck_type_constraint {
    my ( $type_name, $methods ) = @_;

    Moose::Meta::TypeConstraint::DuckType->new(
        name => $type_name || '__ANON__',
        methods => $methods,
    );
}

## --------------------------------------------------------
## desugaring functions ...
## --------------------------------------------------------

sub _create_type_constraint ($$$;$$) {
    my $name      = shift;
    my $parent    = shift;
    my $check     = shift;
    my $message   = shift;
    my $optimized = shift;

    my $pkg_defined_in = scalar( caller(1) );

    if ( defined $name ) {
        my $type = $REGISTRY->get_type_constraint($name);

        ( $type->_package_defined_in eq $pkg_defined_in )
            || _confess(
                  "The type constraint '$name' has already been created in "
                . $type->_package_defined_in
                . " and cannot be created again in "
                . $pkg_defined_in )
            if defined $type;

        $name =~ /^[\w:\.]+$/
            or die qq{$name contains invalid characters for a type name.}
            . qq{ Names can contain alphanumeric character, ":", and "."\n};
    }

    my %opts = (
        name               => $name,
        package_defined_in => $pkg_defined_in,

        ( $check     ? ( constraint => $check )     : () ),
        ( $message   ? ( message    => $message )   : () ),
        ( $optimized ? ( optimized  => $optimized ) : () ),
    );

    my $constraint;
    if (
        defined $parent
        and $parent
        = blessed $parent
        ? $parent
        : find_or_create_isa_type_constraint($parent)
        ) {
        $constraint = $parent->create_child_type(%opts);
    }
    else {
        $constraint = Moose::Meta::TypeConstraint->new(%opts);
    }

    $REGISTRY->add_type_constraint($constraint)
        if defined $name;

    return $constraint;
}

sub _install_type_coercions ($$) {
    my ( $type_name, $coercion_map ) = @_;
    my $type = find_type_constraint($type_name);
    ( defined $type )
        || __PACKAGE__->_throw_error(
        "Cannot find type '$type_name', perhaps you forgot to load it");
    if ( $type->has_coercion ) {
        $type->coercion->add_type_coercions(@$coercion_map);
    }
    else {
        my $type_coercion = Moose::Meta::TypeCoercion->new(
            type_coercion_map => $coercion_map,
            type_constraint   => $type
        );
        $type->coercion($type_coercion);
    }
}

## --------------------------------------------------------
## type notation parsing ...
## --------------------------------------------------------

{

    # All I have to say is mugwump++ cause I know
    # do not even have enough regexp-fu to be able
    # to have written this (I can only barely
    # understand it as it is)
    # - SL

    use re "eval";

    my $valid_chars = qr{[\w:\.]};
    my $type_atom   = qr{ $valid_chars+ };

    my $any;

    my $type = qr{  $valid_chars+  (?: \[ \s* (??{$any})   \s* \] )? }x;
    my $type_capture_parts
        = qr{ ($valid_chars+) (?: \[ \s* ((??{$any})) \s* \] )? }x;
    my $type_with_parameter
        = qr{  $valid_chars+      \[ \s* (??{$any})   \s* \]    }x;

    my $op_union = qr{ \s* \| \s* }x;
    my $union    = qr{ $type (?: $op_union $type )+ }x;

    $any = qr{ $type | $union }x;

    sub _parse_parameterized_type_constraint {
        { no warnings 'void'; $any; }  # force capture of interpolated lexical
        $_[0] =~ m{ $type_capture_parts }x;
        return ( $1, $2 );
    }

    sub _detect_parameterized_type_constraint {
        { no warnings 'void'; $any; }  # force capture of interpolated lexical
        $_[0] =~ m{ ^ $type_with_parameter $ }x;
    }

    sub _parse_type_constraint_union {
        { no warnings 'void'; $any; }  # force capture of interpolated lexical
        my $given = shift;
        my @rv;
        while ( $given =~ m{ \G (?: $op_union )? ($type) }gcx ) {
            push @rv => $1;
        }
        ( pos($given) eq length($given) )
            || __PACKAGE__->_throw_error( "'$given' didn't parse (parse-pos="
                . pos($given)
                . " and str-length="
                . length($given)
                . ")" );
        @rv;
    }

    sub _detect_type_constraint_union {
        { no warnings 'void'; $any; }  # force capture of interpolated lexical
        $_[0] =~ m{^ $type $op_union $type ( $op_union .* )? $}x;
    }
}

## --------------------------------------------------------
# define some basic built-in types
## --------------------------------------------------------

# By making these classes immutable before creating all the types we
# below, we avoid repeatedly calling the slow MOP-based accessors.
$_->make_immutable(
    inline_constructor => 1,
    constructor_name   => "_new",

    # these are Class::MOP accessors, so they need inlining
    inline_accessors => 1
    ) for grep { $_->is_mutable }
    map { Class::MOP::class_of($_) }
    qw(
    Moose::Meta::TypeConstraint
    Moose::Meta::TypeConstraint::Union
    Moose::Meta::TypeConstraint::Parameterized
    Moose::Meta::TypeConstraint::Parameterizable
    Moose::Meta::TypeConstraint::Class
    Moose::Meta::TypeConstraint::Role
    Moose::Meta::TypeConstraint::Enum
    Moose::Meta::TypeConstraint::DuckType
    Moose::Meta::TypeConstraint::Registry
);

type 'Any'  => where {1};    # meta-type including all
subtype 'Item' => as 'Any';  # base-type

subtype 'Undef'   => as 'Item' => where { !defined($_) };
subtype 'Defined' => as 'Item' => where { defined($_) };

subtype 'Bool' => as 'Item' =>
    where { !defined($_) || $_ eq "" || "$_" eq '1' || "$_" eq '0' };

subtype 'Value' => as 'Defined' => where { !ref($_) } =>
    optimize_as \&Moose::Util::TypeConstraints::OptimizedConstraints::Value;

subtype 'Ref' => as 'Defined' => where { ref($_) } =>
    optimize_as \&Moose::Util::TypeConstraints::OptimizedConstraints::Ref;

subtype 'Str' => as 'Value' => where {1} =>
    optimize_as \&Moose::Util::TypeConstraints::OptimizedConstraints::Str;

subtype 'Num' => as 'Str' =>
    where { Scalar::Util::looks_like_number($_) } =>
    optimize_as \&Moose::Util::TypeConstraints::OptimizedConstraints::Num;

subtype 'Int' => as 'Num' => where { "$_" =~ /^-?[0-9]+$/ } =>
    optimize_as \&Moose::Util::TypeConstraints::OptimizedConstraints::Int;

subtype 'ScalarRef' => as 'Ref' => where { ref($_) eq 'SCALAR' } =>
    optimize_as
    \&Moose::Util::TypeConstraints::OptimizedConstraints::ScalarRef;
subtype 'CodeRef' => as 'Ref' => where { ref($_) eq 'CODE' } =>
    optimize_as \&Moose::Util::TypeConstraints::OptimizedConstraints::CodeRef;
subtype 'RegexpRef' => as 'Ref' => where { ref($_) eq 'Regexp' } =>
    optimize_as
    \&Moose::Util::TypeConstraints::OptimizedConstraints::RegexpRef;
subtype 'GlobRef' => as 'Ref' => where { ref($_) eq 'GLOB' } =>
    optimize_as \&Moose::Util::TypeConstraints::OptimizedConstraints::GlobRef;

# NOTE:
# scalar filehandles are GLOB refs,
# but a GLOB ref is not always a filehandle
subtype 'FileHandle' => as 'GlobRef' => where {
    Scalar::Util::openhandle($_) || ( blessed($_) && $_->isa("IO::Handle") );
} => optimize_as
    \&Moose::Util::TypeConstraints::OptimizedConstraints::FileHandle;

# NOTE:
# blessed(qr/.../) returns true,.. how odd
subtype 'Object' => as 'Ref' =>
    where { blessed($_) && blessed($_) ne 'Regexp' } =>
    optimize_as \&Moose::Util::TypeConstraints::OptimizedConstraints::Object;

# This type is deprecated.
subtype 'Role' => as 'Object' => where { $_->can('does') } =>
    optimize_as \&Moose::Util::TypeConstraints::OptimizedConstraints::Role;

my $_class_name_checker = sub { };

subtype 'ClassName' => as 'Str' =>
    where { Class::MOP::is_class_loaded($_) } => optimize_as
    \&Moose::Util::TypeConstraints::OptimizedConstraints::ClassName;

subtype 'RoleName' => as 'ClassName' => where {
    (Class::MOP::class_of($_) || return)->isa('Moose::Meta::Role');
} => optimize_as
    \&Moose::Util::TypeConstraints::OptimizedConstraints::RoleName;

## --------------------------------------------------------
# parameterizable types ...

$REGISTRY->add_type_constraint(
    Moose::Meta::TypeConstraint::Parameterizable->new(
        name               => 'ArrayRef',
        package_defined_in => __PACKAGE__,
        parent             => find_type_constraint('Ref'),
        constraint         => sub { ref($_) eq 'ARRAY' },
        optimized =>
            \&Moose::Util::TypeConstraints::OptimizedConstraints::ArrayRef,
        constraint_generator => sub {
            my $type_parameter = shift;
            my $check          = $type_parameter->_compiled_type_constraint;
            return sub {
                foreach my $x (@$_) {
                    ( $check->($x) ) || return;
                }
                1;
                }
        }
    )
);

$REGISTRY->add_type_constraint(
    Moose::Meta::TypeConstraint::Parameterizable->new(
        name               => 'HashRef',
        package_defined_in => __PACKAGE__,
        parent             => find_type_constraint('Ref'),
        constraint         => sub { ref($_) eq 'HASH' },
        optimized =>
            \&Moose::Util::TypeConstraints::OptimizedConstraints::HashRef,
        constraint_generator => sub {
            my $type_parameter = shift;
            my $check          = $type_parameter->_compiled_type_constraint;
            return sub {
                foreach my $x ( values %$_ ) {
                    ( $check->($x) ) || return;
                }
                1;
                }
        }
    )
);

$REGISTRY->add_type_constraint(
    Moose::Meta::TypeConstraint::Parameterizable->new(
        name                 => 'Maybe',
        package_defined_in   => __PACKAGE__,
        parent               => find_type_constraint('Item'),
        constraint           => sub {1},
        constraint_generator => sub {
            my $type_parameter = shift;
            my $check          = $type_parameter->_compiled_type_constraint;
            return sub {
                return 1 if not( defined($_) ) || $check->($_);
                return;
                }
        }
    )
);

my @PARAMETERIZABLE_TYPES
    = map { $REGISTRY->get_type_constraint($_) } qw[ArrayRef HashRef Maybe];

sub get_all_parameterizable_types {@PARAMETERIZABLE_TYPES}

sub add_parameterizable_type {
    my $type = shift;
    ( blessed $type
            && $type->isa('Moose::Meta::TypeConstraint::Parameterizable') )
        || __PACKAGE__->_throw_error(
        "Type must be a Moose::Meta::TypeConstraint::Parameterizable not $type"
        );
    push @PARAMETERIZABLE_TYPES => $type;
}

## --------------------------------------------------------
# end of built-in types ...
## --------------------------------------------------------

{
    my @BUILTINS = list_all_type_constraints();
    sub list_all_builtin_type_constraints {@BUILTINS}
}

sub _throw_error {
    shift;
    require Moose;
    unshift @_, 'Moose';
    goto &Moose::throw_error;
}

1;

__END__

=pod

=head1 NAME

Moose::Util::TypeConstraints - Type constraint system for Moose

=head1 SYNOPSIS

  use Moose::Util::TypeConstraints;

  subtype 'Natural'
      => as 'Int'
      => where { $_ > 0 };

  subtype 'NaturalLessThanTen'
      => as 'Natural'
      => where { $_ < 10 }
      => message { "This number ($_) is not less than ten!" };

  coerce 'Num'
      => from 'Str'
        => via { 0+$_ };

  enum 'RGBColors' => qw(red green blue);

  no Moose::Util::TypeConstraints;

=head1 DESCRIPTION

This module provides Moose with the ability to create custom type
constraints to be used in attribute definition.

=head2 Important Caveat

This is B<NOT> a type system for Perl 5. These are type constraints,
and they are not used by Moose unless you tell it to. No type
inference is performed, expressions are not typed, etc. etc. etc.

A type constraint is at heart a small "check if a value is valid"
function. A constraint can be associated with an attribute. This
simplifies parameter validation, and makes your code clearer to read,
because you can refer to constraints by name.

=head2 Slightly Less Important Caveat

It is B<always> a good idea to quote your type names.

This prevents Perl from trying to execute the call as an indirect
object call. This can be an issue when you have a subtype with the
same name as a valid class.

For instance:

  subtype DateTime => as Object => where { $_->isa('DateTime') };

will I<just work>, while this:

  use DateTime;
  subtype DateTime => as Object => where { $_->isa('DateTime') };

will fail silently and cause many headaches. The simple way to solve
this, as well as future proof your subtypes from classes which have
yet to have been created, is to quote the type name:

  use DateTime;
  subtype 'DateTime' => as 'Object' => where { $_->isa('DateTime') };

=head2 Default Type Constraints

This module also provides a simple hierarchy for Perl 5 types, here is
that hierarchy represented visually.

  Any
  Item
      Bool
      Maybe[`a]
      Undef
      Defined
          Value
              Num
                  Int
              Str
                  ClassName
                  RoleName
          Ref
              ScalarRef
              ArrayRef[`a]
              HashRef[`a]
              CodeRef
              RegexpRef
              GlobRef
                  FileHandle
              Object

B<NOTE:> Any type followed by a type parameter C<[`a]> can be
parameterized, this means you can say:

  ArrayRef[Int]    # an array of integers
  HashRef[CodeRef] # a hash of str to CODE ref mappings
  Maybe[Str]       # value may be a string, may be undefined

If Moose finds a name in brackets that it does not recognize as an
existing type, it assumes that this is a class name, for example
C<ArrayRef[DateTime]>.

B<NOTE:> Unless you parameterize a type, then it is invalid to include
the square brackets. I.e. C<ArrayRef[]> will be treated as a new type
name, I<not> as a parameterization of C<ArrayRef>.

B<NOTE:> The C<Undef> type constraint for the most part works
correctly now, but edge cases may still exist, please use it
sparingly.

B<NOTE:> The C<ClassName> type constraint does a complex package
existence check. This means that your class B<must> be loaded for this
type constraint to pass.

B<NOTE:> The C<RoleName> constraint checks a string is a I<package
name> which is a role, like C<'MyApp::Role::Comparable'>.

=head2 Type Constraint Naming

Type name declared via this module can only contain alphanumeric
characters, colons (:), and periods (.).

Since the types created by this module are global, it is suggested
that you namespace your types just as you would namespace your
modules. So instead of creating a I<Color> type for your
B<My::Graphics> module, you would call the type
I<My::Graphics::Types::Color> instead.

=head2 Use with Other Constraint Modules

This module can play nicely with other constraint modules with some
slight tweaking. The C<where> clause in types is expected to be a
C<CODE> reference which checks it's first argument and returns a
boolean. Since most constraint modules work in a similar way, it
should be simple to adapt them to work with Moose.

For instance, this is how you could use it with
L<Declare::Constraints::Simple> to declare a completely new type.

  type 'HashOfArrayOfObjects',
      {
      where => IsHashRef(
          -keys   => HasLength,
          -values => IsArrayRef(IsObject)
      )
  };

For more examples see the F<t/200_examples/004_example_w_DCS.t> test
file.

Here is an example of using L<Test::Deep> and it's non-test
related C<eq_deeply> function.

  type 'ArrayOfHashOfBarsAndRandomNumbers'
      => where {
          eq_deeply($_,
              array_each(subhashof({
                  bar           => isa('Bar'),
                  random_number => ignore()
              })))
        };

For a complete example see the
F<t/200_examples/005_example_w_TestDeep.t> test file.

=head1 FUNCTIONS

=head2 Type Constraint Constructors

The following functions are used to create type constraints.  They
will also register the type constraints your create in a global
registry that is used to look types up by name.

See the L<SYNOPSIS> for an example of how to use these.

=over 4

=item B<< subtype 'Name' => as 'Parent' => where { } ... >>

This creates a named subtype.

If you provide a parent that Moose does not recognize, it will
automatically create a new class type constraint for this name.

When creating a named type, the C<subtype> function should either be
called with the sugar helpers (C<where>, C<message>, etc), or with a
name and a hashref of parameters:

 subtype( 'Foo', { where => ..., message => ... } );

The valid hashref keys are C<as> (the parent), C<where>, C<message>,
and C<optimize_as>.

=item B<< subtype as 'Parent' => where { } ... >>

This creates an unnamed subtype and will return the type
constraint meta-object, which will be an instance of
L<Moose::Meta::TypeConstraint>.

When creating an anonymous type, the C<subtype> function should either
be called with the sugar helpers (C<where>, C<message>, etc), or with
just a hashref of parameters:

 subtype( { where => ..., message => ... } );

=item B<class_type ($class, ?$options)>

Creates a new subtype of C<Object> with the name C<$class> and the
metaclass L<Moose::Meta::TypeConstraint::Class>.

=item B<role_type ($role, ?$options)>

Creates a C<Role> type constraint with the name C<$role> and the
metaclass L<Moose::Meta::TypeConstraint::Role>.

=item B<maybe_type ($type)>

Creates a type constraint for either C<undef> or something of the
given type.

=item B<duck_type ($name, @methods)>

This will create a subtype of Object and test to make sure the value
C<can()> do the methods in C<@methods>.

This is intended as an easy way to accept non-Moose objects that
provide a certain interface. If you're using Moose classes, we
recommend that you use a C<requires>-only Role instead.

=item B<duck_type (\@methods)>

If passed an ARRAY reference instead of the C<$name>, C<@methods>
pair, this will create an unnamed duck type. This can be used in an
attribute definition like so:

  has 'cache' => (
      is  => 'ro',
      isa => duck_type( [qw( get_set )] ),
  );

=item B<enum ($name, @values)>

This will create a basic subtype for a given set of strings.
The resulting constraint will be a subtype of C<Str> and
will match any of the items in C<@values>. It is case sensitive.
See the L<SYNOPSIS> for a simple example.

B<NOTE:> This is not a true proper enum type, it is simply
a convenient constraint builder.

=item B<enum (\@values)>

If passed an ARRAY reference instead of the C<$name>, C<@values> pair,
this will create an unnamed enum. This can then be used in an attribute
definition like so:

  has 'sort_order' => (
      is  => 'ro',
      isa => enum([qw[ ascending descending ]]),
  );

=item B<as 'Parent'>

This is just sugar for the type constraint construction syntax.

It takes a single argument, which is the name of a parent type.

=item B<where { ... }>

This is just sugar for the type constraint construction syntax.

It takes a subroutine reference as an argument. When the type
constraint is tested, the reference is run with the value to be tested
in C<$_>. This reference should return true or false to indicate
whether or not the constraint check passed.

=item B<message { ... }>

This is just sugar for the type constraint construction syntax.

It takes a subroutine reference as an argument. When the type
constraint fails, then the code block is run with the value provided
in C<$_>. This reference should return a string, which will be used in
the text of the exception thrown.

=item B<optimize_as { ... }>

This can be used to define a "hand optimized" version of your
type constraint which can be used to avoid traversing a subtype
constraint hierarchy.

B<NOTE:> You should only use this if you know what you are doing,
all the built in types use this, so your subtypes (assuming they
are shallow) will not likely need to use this.

=item B<< type 'Name' => where { } ... >>

This creates a base type, which has no parent.

The C<type> function should either be called with the sugar helpers
(C<where>, C<message>, etc), or with a name and a hashref of
parameters:

  type( 'Foo', { where => ..., message => ... } );

The valid hashref keys are C<where>, C<message>, and C<optimize_as>.

=back

=head2 Type Coercion Constructors

You can define coercions for type constraints, which allow you to
automatically transform values to something valid for the type
constraint. If you ask your accessor to coerce, then Moose will run
the type-coercion code first, followed by the type constraint
check. This feature should be used carefully as it is very powerful
and could easily take off a limb if you are not careful.

See the L<SYNOPSIS> for an example of how to use these.

=over 4

=item B<< coerce 'Name' => from 'OtherName' => via { ... } >>

This defines a coercion from one type to another. The C<Name> argument
is the type you are coercing I<to>.

=item B<from 'OtherName'>

This is just sugar for the type coercion construction syntax.

It takes a single type name (or type object), which is the type being
coerced I<from>.

=item B<via { ... }>

This is just sugar for the type coercion construction syntax.

It takes a subroutine reference. This reference will be called with
the value to be coerced in C<$_>. It is expected to return a new value
of the proper type for the coercion.

=back

=head2 Creating and Finding Type Constraints

These are additional functions for creating and finding type
constraints. Most of these functions are not available for
importing. The ones that are importable as specified.

=over 4

=item B<find_type_constraint($type_name)>

This function can be used to locate the L<Moose::Meta::TypeConstraint>
object for a named type.

This function is importable.

=item B<register_type_constraint($type_object)>

This function will register a L<Moose::Meta::TypeConstraint> with the
global type registry.

This function is importable.

=item B<normalize_type_constraint_name($type_constraint_name)>

This method takes a type constraint name and returns the normalized
form. This removes any whitespace in the string.

=item B<create_type_constraint_union($pipe_separated_types | @type_constraint_names)>

This can take a union type specification like C<'Int|ArrayRef[Int]'>,
or a list of names. It returns a new
L<Moose::Meta::TypeConstraint::Union> object.

=item B<create_parameterized_type_constraint($type_name)>

Given a C<$type_name> in the form of C<'BaseType[ContainerType]'>,
this will create a new L<Moose::Meta::TypeConstraint::Parameterized>
object. The C<BaseType> must exist already exist as a parameterizable
type.

=item B<create_class_type_constraint($class, $options)>

Given a class name this function will create a new
L<Moose::Meta::TypeConstraint::Class> object for that class name.

The C<$options> is a hash reference that will be passed to the
L<Moose::Meta::TypeConstraint::Class> constructor (as a hash).

=item B<create_role_type_constraint($role, $options)>

Given a role name this function will create a new
L<Moose::Meta::TypeConstraint::Role> object for that role name.

The C<$options> is a hash reference that will be passed to the
L<Moose::Meta::TypeConstraint::Role> constructor (as a hash).

=item B<create_enum_type_constraint($name, $values)>

Given a enum name this function will create a new
L<Moose::Meta::TypeConstraint::Enum> object for that enum name.

=item B<create_duck_type_constraint($name, $methods)>

Given a duck type name this function will create a new
L<Moose::Meta::TypeConstraint::DuckType> object for that enum name.

=item B<find_or_parse_type_constraint($type_name)>

Given a type name, this first attempts to find a matching constraint
in the global registry.

If the type name is a union or parameterized type, it will create a
new object of the appropriate, but if given a "regular" type that does
not yet exist, it simply returns false.

When given a union or parameterized type, the member or base type must
already exist.

If it creates a new union or parameterized type, it will add it to the
global registry.

=item B<find_or_create_isa_type_constraint($type_name)>

=item B<find_or_create_does_type_constraint($type_name)>

These functions will first call C<find_or_parse_type_constraint>. If
that function does not return a type, a new anonymous type object will
be created.

The C<isa> variant will use C<create_class_type_constraint> and the
C<does> variant will use C<create_role_type_constraint>.

=item B<get_type_constraint_registry>

Returns the L<Moose::Meta::TypeConstraint::Registry> object which
keeps track of all type constraints.

=item B<list_all_type_constraints>

This will return a list of type constraint names in the global
registry. You can then fetch the actual type object using
C<find_type_constraint($type_name)>.

=item B<list_all_builtin_type_constraints>

This will return a list of builtin type constraints, meaning those
which are defined in this module. See the L<Default Type Constraints>
section for a complete list.

=item B<export_type_constraints_as_functions>

This will export all the current type constraints as functions into
the caller's namespace (C<Int()>, C<Str()>, etc). Right now, this is
mostly used for testing, but it might prove useful to others.

=item B<get_all_parameterizable_types>

This returns all the parameterizable types that have been registered,
as a list of type objects.

=item B<add_parameterizable_type($type)>

Adds C<$type> to the list of parameterizable types

=back

=head1 BUGS

All complex software has bugs lurking in it, and this module is no
exception. If you find a bug please either email me, or add the bug
to cpan-RT.

=head1 AUTHOR

Stevan Little E<lt>stevan@iinteractive.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2006-2009 by Infinity Interactive, Inc.

L<http://www.iinteractive.com>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
