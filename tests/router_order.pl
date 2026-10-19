use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;

use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use VisLlama::Catalog ();

my $items = [
    {alias=>'first', enabled=>1, load_on_startup=>1},
    {alias=>'second', enabled=>0, load_on_startup=>0},
    {alias=>'third', enabled=>1, load_on_startup=>1},
];
my $result = VisLlama::Catalog::reorder_router_presets($items,['third','second','first']);
die 'Model reorder lost object identity or order' unless
    $result->[0] == $items->[2] && $result->[1] == $items->[1] && $result->[2] == $items->[0];
die 'Disabled model was changed' if $result->[1]{enabled};
eval { VisLlama::Catalog::reorder_router_presets($items,['third','third','first']) };
die 'Repeated alias accepted' unless $@ =~ /repeated model/;
eval { VisLlama::Catalog::reorder_router_presets($items,['third','first']) };
die 'Incomplete order accepted' unless $@ =~ /complete ordered/;
print "Router model order passed\n";
