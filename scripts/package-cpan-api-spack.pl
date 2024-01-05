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
use Getopt::Long;
use Software::LicenseUtils;

# Needs MetaCPAN::Client and Software::LicenseUtils, install with:
# $ cpanm MetaCPAN::Client Software::LicenseUtils
#
# Usage:
# go to the rot dir of your spack checkout
# make sure the spack command works
# Then:
# $ package-cpan-api-spack.pl My::Module
# This will do:
# git checkout develop, update, create and checkout new branch
# Create a new Spack package for the given Perl module
# Run spack style
# Do a test installation and run standalone tests
# If this worked, git commit the change for the new package
#
# The next thing you would do is to manually check if everything is OK, then git
# push to your staging repo and do a PR.
#
# The script finds dependencies, filtered for modules that
# are in Core or available in Spack by default.
# Will also find the correct distribution if called with a module name that is
# not the main module, e.g. LWP::Protocol::ftp will create perl-libwww-perl
#
# If a needed dependency is missing, the script will alert you to the fact and
# stop.
#
# This script can't do magic.
# You still have to add all non-Perl dependencies and look at the build.
# If it is a pure Perl package with a standard build, most likely the created
# packages will work without changes.
# If there are any other dependencies (binaries, libraries), these will not be
# picked up. If the build needs anything special, this is also not added
# automatically.
#
# Also, caveat: The script pulls data from metacpan. The data there usually is
# extracted from the distribution. Sometimes that data is wrong.

my ($pkg_only, $tst_only);
GetOptions(
    'p' => \$pkg_only,
    't' => \$tst_only,
) or die_usage();

sub die_usage {
    die "Usage: $0 [-p] [-t] Ex::Pkg";
}

my $mcpan  = MetaCPAN::Client->new();
my @stack = ();
my %perl2spack;
#
# Set to 1 to enable lots of output
my $dbg = 0;
my $destdir = 'var/spack/repos/builtin/packages/';

unless (-d $destdir) {
    die "Wrong cwd. Must be run from the spack root dir.";
}

my $mod = shift or die_usage();

if (Module::CoreList::is_core($mod)) {
    say "This is a core module";
    exit 0;
}

chdir $destdir;
if ($tst_only) {
    my ($name, $main_module) = spack_name($mcpan, $mod);
    tests($name, $main_module);
    exit(0);
}

my $template;
{
    local $/ = undef;
    $template = <DATA>;
}

my $dirname = $perl2spack{$mod};

my $perlname;

unless ($dirname) {
    my ($name, $main_module) = spack_name($mcpan, $mod);
    $perlname = $main_module;
    $perl2spack{$mod} = $name;
    $perl2spack{$main_module} = $name;
    $dirname = $name;
}

if ($dirname and -d $dirname) {
    say "Package for $mod ($dirname) exists.";
    exit(0);
}
my $new_spack_pkg = $dirname;

say "Creating package for $mod";
my $branch;

if (! $pkg_only) {
    $branch = do_branch();
}

push @stack, @{create_single_package($mod, 1)};
exit(0) if $pkg_only;

while (@stack) {
    @stack = uniq(@stack);
    $mod = shift @stack;
    my $dirname = $perl2spack{$mod};

    unless ($dirname) {
        my ($name, $main_module) = spack_name($mcpan, $mod);

        $perl2spack{$mod} = $name;
        $perl2spack{$main_module} = $name;
        $dirname = $name;
    }

    if ($dirname and -d $dirname) {
        say "Package for $mod exists.";
        next;
    }
    say "Warning: missing $mod";

    my $txt = `git checkout develop`;
    die "Err: $txt" if ($? != 0);

    say "Delete branch $branch";
    $txt = `git branch -D $branch`;

    say "rm -rf $destdir/$new_spack_pkg/package.py";
    exit(1);
}
tests($new_spack_pkg, $perlname);

sub tests {
    my ($new_spack_pkg, $perlname) = @_;

    say "Running check: spack style -s mypy $new_spack_pkg/package.py";
    $| = 1;
    system("spack style -s mypy $new_spack_pkg/package.py") and die "Error in style check";
    system("spack -e dev1 find |perl -nE 'last if /==\> Installed packages/; next if /==/; last if /^\$/; print'|xargs spack -e dev1 remove") and die "Remove failed";
    system("spack -e dev1 add $new_spack_pkg") and die "Error adding package to dev1";
    system("spack -e dev1 install --test root") and die "Error installing package"; 
    system("spack -e dev1 test run $new_spack_pkg") and die "Error testing package";
    system("spack -e dev1 remove $new_spack_pkg") and die "Error removing package";
}

say "Tests OK. Adding package to git";
my $txt = `git add $new_spack_pkg/package.py`;
die "Error in git add: $txt" if ($? != 0);

say "Doing git commit";
$txt = `git commit -m "$new_spack_pkg: New package" -m "Adds $perlname"`;
die "Error in git add: $txt" if ($? != 0);

say "Finished for $new_spack_pkg";

sub spack_license {
    my $licenses = shift;

    return unless $licenses;


    my $lic_spdx;

    for my $short_lic (@$licenses) {
        my @guesses = Software::LicenseUtils->guess_license_from_meta_key($short_lic);

        foreach (@guesses) {
            push @$lic_spdx, $_->spdx_expression;
        }
    }

    return join(" OR ", @$lic_spdx);
}

sub create_single_package {
    my $modname = shift or die "Need a Perl module name, e.g. Test::More";
    my $write = shift;

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

    #say "#" x 80;

    #say "Pkg Name:";
    #say $distname;

    my $spack_pkg = $distname;
    $spack_pkg = lc $spack_pkg;
    $spack_pkg =~ s/_/-/g;
    $spack_pkg = 'perl-' . $spack_pkg;
    #say $spack_pkg;

    #say "Download URL:";
    my $url = $module->{'download_url'};

    #say "Description:";
    my $desc = $release->{'abstract'};
    $desc //= $module->{'abstract'};
    $desc = ucfirst $desc;
    #say "Homepage:";
    my $homepage = "https://metacpan.org/pod/$modname";

    my $version = $module->{'version'};

    #say "Dependencies:";
    my $reqs = $release->{'metadata'}->{'prereqs'};
    my $hash = $release->{'checksum_sha256'};

    my $licenses = $release->{'license'};
    my $spack_license = spack_license($licenses);

    my @perl_versions = ();

    my $deps;
    my $deptemplate = '    depends_on("NAME", type=(TYPE))';

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

        $dbg && say "DBG: Dep name is $onedep";
        my %spack_sect;
        for (@$perl_sect) {
            when ('configure') {$spack_sect{'build'} = 1}
            when ('build') {$spack_sect{'build'} = 1; $spack_sect{'link'} = 1;}
            when ('runtime') {$spack_sect{'build'} = 1; $spack_sect{'run'} = 1; $spack_sect{'test'} = 1;}
            when ('test') {$spack_sect{'build'} = 1; $spack_sect{'test'} = 1}
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


    my $py_pkg = $distname;
    $py_pkg = 'perl-' . lc($py_pkg);
    $py_pkg =~ s/(?<![A-Za-z0-9])(\w)/\U$1/g;
    $py_pkg =~ s/[_-]//g;

    my @sections;

    # This is the package definition
    my $def = $template;
    $def =~ s/PACKAGE/$py_pkg/;
    $def =~ s/DESCRIPTION/$desc/;
    $def =~ s/HOMEPAGE/$homepage/;
    $def =~ s/URL/$url/;

    push(@sections, $def);

    my $lic;
    if ($spack_license) {
        $lic = '    license("' . $spack_license . '")' . "\n";
    }
    push(@sections, $lic) if $lic;

    my $spack_vers = '    version("VERSION", sha256="HASH")' . "\n";
    $spack_vers =~ s/VERSION/$version/;
    $spack_vers =~ s/HASH/$hash/;
    push(@sections, $spack_vers);

    push(@sections, $deps) if $deps;

    my $test = <<'EOT';
    def test_use(self):
        """Test 'use module'"""
        options = ["-we", 'use strict; use MODNAME; print("OK\n")']

        perl = self.spec["perl"].command
        out = perl(*options, output=str.split, error=str.split)
        assert "OK" in out
EOT
    $test =~ s/MODNAME/$modname/;

    push(@sections, $test) if $test;

    #say "Run:\n\necho \"1\" |spack create --skip-editor -n $spack_pkg $module->{'download_url'}";
    #say "Then replace package contents with:\n\n$def";
    if ($write) {
        $def =~ s/^\n\z//m;
        mkdir($spack_pkg) or die "Error: mkdir: $!";
        open (my $fh, '>', "$spack_pkg/package.py") or die "Error: open: $!";
        print $fh join("\n", @sections);
        close($fh) or die "Error: close: $!";
    }

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

# creates new branch after git pull in develop
sub do_branch {
    my $branch = `git branch -l new-pack* --format '%(refname:short)'`;
    my @branches = split(/^/m, $branch);
    @branches = sort {$a =~ /(\d+)/; my $fi = $1; $b =~ /(\d+)/; my $la = $1; $fi <=> $la} @branches;
    $branch = $branches[-1];
    chomp $branch;
    unless ($branch) {
        $branch = "new-package-1";
    } else {
        say "Old branch: $branch";
        $branch =~ /^(.*?)(\d+)$/;
        $branch = $1 . ($2 + 1);
    }

    say "Checkout develop and update";
    my $txt = `git checkout develop && git pull`;
    die "Err: $txt" if ($? != 0);

    say "Create branch $branch";
    $txt = `git checkout -b $branch`;
    die "Err: $txt" if ($? != 0);

    return $branch;
}

# This is the template that's used to create the spack package.py file.
# You can edit this.

__DATA__
# Copyright 2013-2024 Lawrence Livermore National Security, LLC and other
# Spack Project Developers. See the top-level COPYRIGHT file for details.
#
# SPDX-License-Identifier: (Apache-2.0 OR MIT)

from spack.package import *


class PACKAGE(PerlPackage):
    """DESCRIPTION"""

    homepage = "HOMEPAGE"
    url = "URL"

    maintainers("EbiArnie")
