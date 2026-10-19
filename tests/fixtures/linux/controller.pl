# Run the real control listener against a temporary installation for SIGTERM tests.
use strict;use warnings;use FindBin qw($RealBin);use lib "$RealBin/../../../lib";
use VisLlama::App ();use VisLlama::Paths ();use VisLlama::Context qw(%CFG);
my ($root,$port)=@ARGV;
no warnings 'redefine';*VisLlama::Paths::app_base_dir=sub {$root};
$CFG{listen_port}=$port;
exit VisLlama::App::run();
