#!/usr/bin/env perl
use warnings;
use strict;
use feature 'say';

use v5.10.1;
no warnings 'experimental';

use Module::CoreList;
use MetaCPAN::Client;

use Data::Dumper;
use List::Util 'uniq';
use version;


# Set to 1 to enable lots of output
my $dbg = 0;

# Needs MetaCPAN::Client, install with:
# $ cpanm MetaCPAN::Client
#
# Usage: $0 My::Module
# This creates directories and files in the current directory like this:
# perl-pkg1/package.py
# perl-pkg2/package.py
# Finds dependencies and also creates their packages, filtered for modules that
# are in Core or available in Spack by default.
# Will also find the correct distribution if called with a module name that is
# not the main module, e.g. LWP::Protocol::ftp will create perl-libwww-perl
#
# This script can't do magic.
# You still have to add all non-Perl dependencies and look at the build.
# If it is a pure Perl package with a standard build, most likely the created
# packages will work without changes.
# If there are any other dependencies (binaries, libraries), these will not be
# picked up. If the build needs anything special, this is also not added
# automatically.

my $initial_mod = shift or die "Need a Perl module name, e.g. Test::More\n";
($initial_mod =~ /^[\w:_-]+$/) or die "Need a Perl module name, e.g. Test::More\n";

if (Module::CoreList::is_core($initial_mod)) {
    say "This is a core module";
    exit 0;
}


my $template;
{
    local $/ = undef;
    $template = <DATA>;
}

my $mcpan  = MetaCPAN::Client->new();

my %perl2spack;
my @stack = ($initial_mod);

# For each package, get all dependencies. Iterate until we have created packages
# for all of them
while (@stack) {
    @stack = uniq(@stack);
    my $modname = shift @stack;
    my $dirname = $perl2spack{$modname};

    unless ($dirname) {
        my ($distname, $main_module) = spack_name($mcpan, $modname);
        if ($modname ne $main_module) {
            say "Main module for $modname is $main_module, distribution $distname";
        }

        $perl2spack{$modname} = $distname;
        $perl2spack{$main_module} = $distname;
        $dirname = $distname;
    }

    if ($dirname and -d $dirname) {
        say "Package for $dirname exists, skipping";
        next;
    }
    say "Creating package $dirname";
    push @stack, @{create_single_package($modname)};
}


sub create_single_package {
    my $modname = shift or die "Need a Perl module name, e.g. Test::More";

    my $module = $mcpan->module($modname)->{'data'};
    my $distname = $module->{'distribution'};

    my $release = $mcpan->release($distname)->{'data'};
    my $dist = $mcpan->distribution($distname)->{'data'};
    my $package = $mcpan->package($modname)->{'data'};

    $dbg && say "Dist";
    $dbg && print Dumper($dist);

    $dbg && say "Package";
    $dbg && print Dumper($package);

    $dbg && say "Module";
    $dbg && print Dumper($module);

    $dbg && say "Release";
    $dbg && print Dumper($release);

    my $spack_pkg = $distname;
    $spack_pkg = lc $spack_pkg;
    $spack_pkg =~ s/_/-/g;
    $spack_pkg = 'perl-' . $spack_pkg;
    $dbg && say $spack_pkg;

    my $url = $module->{'download_url'};

    my $desc = $release->{'abstract'};
    $desc //= $module->{'abstract'};
    $desc = ucfirst $desc;

    my $homepage = "https://metacpan.org/pod/$modname";

    my $version = $module->{'version'};


    my $reqs = $release->{'metadata'}->{'prereqs'};
    my $hash = $release->{'checksum_sha256'};

    my @perl_versions = ();

    my $deps;
    my $deptemplate = '    depends_on("NAME", type=(TYPE))';

    my %map = (
        'configure' => '"build"',
        'build' => '"build", "link"',
        'runtime' => '"run"',
        'test' => '"test"'
    );

    my %dep;
    my %perldep;

    # Go through the data from the metadata API.
    # Transform Perl dist names to spack package names
    # Transform Perl phases to Spack phases
    for my $section (qw(configure build runtime test)) {
        my $req_ref = $reqs->{$section}->{'requires'};
        my @x = keys %{$req_ref};
        for my $pkg (@x) {
            if ($pkg eq 'perl') {
                push @perl_versions, $req_ref->{$pkg};
                next;
            }
            if (Module::CoreList::is_core($pkg)) {
                $dbg && say "$_ is a core module";
            } else {
                my ($name, $main_module) = spack_name($mcpan, $pkg);

                # Skip this because it is always available in the Perl build system
                # in Spack
                next if ($name eq 'perl-module-build');
                $perldep{$main_module} = 1;

                $perl2spack{$pkg} = $name;
                $perl2spack{$main_module} = $name;

                push @{$dep{$name}->{sections}}, $section;
                if ($pkg eq $main_module) {
                    push @{$dep{$name}->{versions}}, $req_ref->{$pkg};
                }
            }
        }
    }

    @perl_versions = sort { version->parse( $a ) <=> version->parse( $b ) } @perl_versions;
    $dbg && say "Found a minimum Perl version: $perl_versions[-1]" if @perl_versions;

    # If we have a minimum Perl version, add a spack dependency
    if (@perl_versions) {
        my $minperl = $perl_versions[-1] if @perl_versions;
        my $spack_vers = version->parse($minperl)->normal;
        $spack_vers =~ s/v//;
        my $line = $deptemplate;
        my $name = 'perl';
        $name .= "@" . $spack_vers . ":";
        $line =~ s/NAME/$name/;
        $line =~ s/TYPE/"build", "link", "run", "test"/;
        $deps .= "$line\n";
    }

    # Add the dependencies for this module
    for my $onedep (sort keys %dep) {
        my $perl_sect = $dep{$onedep}->{sections};
        $dbg && say "Processing module $onedep";
        my %spack_sect;
        for (@$perl_sect) {
            when ('configure') {$spack_sect{'build'} = 1}
            when ('build') {$spack_sect{'build'} = 1; $spack_sect{'link'} = 1;}
            when ('runtime') {$spack_sect{'run'} = 1}
            when ('test') {$spack_sect{'test'} = 1}
        }
        my $type = join ", ", map {'"' . $_ . '"'} sort keys %spack_sect;

        my $spack_max_version = [sort { version->parse( $a ) <=> version->parse( $b ) } @{$dep{$onedep}->{versions}}]->[-1] // 0;

        my $line = $deptemplate;
        my $name = $onedep;

        my $vers = $spack_max_version;
        $name .= "@" . $vers . ":" if $vers != 0;
        $line =~ s/NAME/$name/;
        $line =~ s/TYPE/$type/;
        $deps .= "$line\n"; 
    }

    # This is the package definition
    my $def = $template;

    my $py_pkg = $distname;
    $py_pkg = 'perl-' . lc($py_pkg);
    $py_pkg =~ s/(?<![A-Za-z0-9])(\w)/\U$1/g;
    $py_pkg =~ s/[_-]//g;

    $deps //= '';

    $def =~ s/PACKAGE/$py_pkg/;

    $def =~ s/DESCRIPTION/$desc/;
    $def =~ s/HOMEPAGE/$homepage/;
    $def =~ s/URL/$url/;
    $def =~ s/VERSION/$version/;
    $def =~ s/HASH/$hash/;
    $def =~ s/DEPENDENCIES/$deps/;

    mkdir($spack_pkg) or die "Error: mkdir: $!";
    open (my $fh, '>', "$spack_pkg/package.py") or die "Error: open: $!";
    print $fh $def;
    close($fh) or die "Error: close: $!";

    return [keys %perldep];
}

sub spack_name {
    my $mcpan = shift;
    my $modname = shift;

    my $module = $mcpan->module($modname)->{'data'};
    my $distname = $module->{'distribution'};
    my $main_module = $mcpan->release($distname)->{'data'}->{'main_module'};
    if ($modname ne $main_module) {
        $dbg && say "Main module for $modname ($distname) is $main_module";
    }

    my $spack_pkg = $distname;
    $spack_pkg = lc $spack_pkg;
    $spack_pkg =~ s/_/-/g;
    $spack_pkg = 'perl-' . $spack_pkg;
    return ($spack_pkg, $main_module);
}


# This is the template that's used to create the spack package.py file.
# You can edit this.

__DATA__
# Copyright 2013-2023 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PACKAGE(PerlPackage):
    """DESCRIPTION"""

    homepage = "HOMEPAGE"
    url = "URL"

    maintainers("EbiArnie")

    version("VERSION", sha256="HASH")

DEPENDENCIES
    # FIXME: Add all non-perl dependencies and cross-check with the actual
    # package build mechanism (e.g. Makefile.PL)

    def configure_args(self):
        # FIXME: Add non-standard arguments
        # FIXME: If not needed delete this function
        args = []
        return args
