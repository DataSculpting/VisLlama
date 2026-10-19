use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;

use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use VisLlama::Catalog ();
no warnings 'redefine';

my $dir = tempdir(CLEANUP => 1);
sub VisLlama::Paths::presets_dir { return $dir }
sub VisLlama::Catalog::safe_build_slug { return $_[0] }
our $fail = 1;
sub VisLlama::Catalog::write_router_ini_for_build {
    my ($items,$build,$path) = @_;
    die 'Simulated VRAM planning failure' if $fail;
    open my $fh, '>', $path or die $!;
    print $fh "version = 1\n[$build]\n";
    close $fh;
}

my $existing = File::Spec->catfile($dir, 'router-models-test.ini');
open my $fh, '>', $existing or die $!;
print $fh "old working catalog\n";
close $fh;
my $items = [{ enabled => 1, build => 'test' }];
eval { VisLlama::Catalog::sync_router_build_inis($items) };
die 'Planning failure not reported' unless $@ =~ /Simulated VRAM planning failure/;
open my $read_fh, '<', $existing or die 'Existing catalog deleted by failed plan';
my $old = do { local $/; <$read_fh> };
die 'Existing catalog changed by failed plan' unless $old eq "old working catalog\n";

$fail = 0;
VisLlama::Catalog::sync_router_build_inis($items);
open $read_fh, '<', $existing or die $!;
my $new = do { local $/; <$read_fh> };
die 'New catalog not installed' unless $new =~ /\[test\]/;
print "Router INI failure recovery passed\n";
