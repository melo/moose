
package Moose::Meta::Class;

use strict;
use warnings;

use Carp         'confess';
use Scalar::Util 'weaken';

our $VERSION = '0.04';

use base 'Class::MOP::Class';

sub construct_instance {
    my ($class, %params) = @_;
    my $instance = $params{'__INSTANCE__'} || {};
    foreach my $attr ($class->compute_all_applicable_attributes()) {
        my $init_arg = $attr->init_arg();
        # try to fetch the init arg from the %params ...
        my $val;        
        if (exists $params{$init_arg}) {
            $val = $params{$init_arg};
        }
        else {
            # skip it if it's lazy
            next if $attr->is_lazy;
            # and die if it is required            
            confess "Attribute (" . $attr->name . ") is required" 
                if $attr->is_required
        }
        # if nothing was in the %params, we can use the 
        # attribute's default value (if it has one)
        if (!defined $val && $attr->has_default) {
            $val = $attr->default($instance); 
        }
		if (defined $val) {
		    if ($attr->has_type_constraint) {
    		    if ($attr->should_coerce && $attr->type_constraint->has_coercion) {
    		        $val = $attr->type_constraint->coercion->coerce($val);
    		    }	
                (defined($attr->type_constraint->check($val))) 
                    || confess "Attribute (" . $attr->name . ") does not pass the type contraint with '$val'";			
            }
		}
        $instance->{$attr->name} = $val;
        if (defined $val && $attr->is_weak_ref) {
            weaken($instance->{$attr->name});
        }
    }
    return $instance;
}

sub add_override_method_modifier {
    my ($self, $name, $method, $_super_package) = @_;
    # need this for roles ...
    $_super_package ||= $self->name;
    my $super = $self->find_next_method_by_name($name);
    (defined $super)
        || confess "You cannot override '$name' because it has no super method";    
    $self->add_method($name => sub {
        my @args = @_;
        no strict   'refs';
        no warnings 'redefine';
        local *{$_super_package . '::super'} = sub { $super->(@args) };
        return $method->(@args);
    });
}

sub add_augment_method_modifier {
    my ($self, $name, $method) = @_;    
    my $super = $self->find_next_method_by_name($name);
    (defined $super)
        || confess "You cannot augment '$name' because it has no super method";
    $self->add_method($name => sub {
        my @args = @_;
        no strict   'refs';
        no warnings 'redefine';
        local *{$super->package_name . '::inner'} = sub { $method->(@args) };
        return $super->(@args);
    });    
}

1;

__END__

=pod

=head1 NAME

Moose::Meta::Class - The Moose metaclass

=head1 DESCRIPTION

This is a subclass of L<Class::MOP::Class> with Moose specific 
extensions.

For the most part, the only time you will ever encounter an 
instance of this class is if you are doing some serious deep 
introspection. To really understand this class, you need to refer 
to the L<Class::MOP::Class> documentation.

=head1 METHODS

=over 4

=item B<construct_instance>

This provides some Moose specific extensions to this method, you 
almost never call this method directly unless you really know what 
you are doing. 

This method makes sure to handle the moose weak-ref, type-constraint
and type coercion features. 

=item B<add_override_method_modifier ($name, $method)>

=item B<add_augment_method_modifier ($name, $method)>

=back

=head1 BUGS

All complex software has bugs lurking in it, and this module is no 
exception. If you find a bug please either email me, or add the bug
to cpan-RT.

=head1 AUTHOR

Stevan Little E<lt>stevan@iinteractive.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2006 by Infinity Interactive, Inc.

L<http://www.iinteractive.com>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut