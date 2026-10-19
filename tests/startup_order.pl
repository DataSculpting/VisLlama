use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Basename qw(dirname);
use File::Spec;

my $file = File::Spec->catfile(dirname(dirname(__FILE__)),'lib','VisLlama','Process.pm');
open my $fh,'<',$file or die $!;
my $source = do { local $/; <$fh> };
require VisLlama::GPUIsolation;
require VisLlama::Engines;
require VisLlama::Lifecycle;
use VisLlama::Context qw($STATE);
my $expected_runtime=VisLlama::Lifecycle::token();
my ($startup) = $source =~ /(my \@startup_errors;\n    \$STATE->\{startup_models\}=\[\];\n    for my \$p \(\@enabled\) \{.*?\n    \}\n)\n    VisLlama::Lifecycle::checkpoint\(\$expected_runtime\);\n    my \$proxy_launcher/s;
die 'Ordered startup stage not found before public proxy launch' unless $startup;

our @events;
sub VisLlama::Router::load_router_model_centrally { my ($alias,$eng)=@_; push @events,"load:$alias:$eng->{build}" }
sub VisLlama::Router::wait_router_model_loaded { my ($eng,$alias)=@_; push @events,"ready:$alias:$eng->{build}" }
my @enabled=(
    {alias=>'first',build=>'build_b',load_on_startup=>1},
    {alias=>'on_demand',build=>'build_a',load_on_startup=>0},
    {alias=>'second',build=>'build_a',load_on_startup=>1},
);
my %engines=(build_a=>{build=>'build_a'},build_b=>{build=>'build_b'});
eval $startup; die $@ if $@;
die 'Startup loads were not serialized in preferred catalog order' unless
    join('|',@events) eq 'load:first:build_b|ready:first:build_b|load:second:build_a|ready:second:build_a';
print "Ordered Router startup passed\n";
