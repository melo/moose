package Moose::Meta::Class::Immutable::Trait;

use strict;
use warnings;

use Class::MOP;

use base 'Class::MOP::Class::Immutable::Trait';

sub add_role { shift->_immutable_cannot_call }

sub calculate_all_roles { @{ $_[0]{__immutable}{calculate_all_roles} ||= [ shift->next::method ] } }

1;
