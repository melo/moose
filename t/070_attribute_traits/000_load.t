#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 1;

use Moose ();
BEGIN {
    use_ok('Moose::Attribute::Native');
}