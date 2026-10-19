use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use VisLlama::Catalog ();
use VisLlama::Errors ();
use VisLlama::Context qw($STATE);

is_deeply(VisLlama::Catalog::args_to_preset_options(['--log-verbosity=4','--fit','off']),
    [['log-verbosity','4'],['fit','off']],'equals and explicit boolean values remain valid INI pairs');
for my $args (['--bad]','x'],["--bad=4\n[section]"],['orphan'],['--no-warmup','orphan'],['--value',{}]) {
    eval { VisLlama::Catalog::args_to_preset_options($args) };
    ok($@,'malformed argument array rejected');
}
is_deeply(VisLlama::Catalog::args_to_preset_options(['--spec-draft-n-min','0','--log-verbosity 4','--device','CUDA3,CUDA0','--fit','off']),
    [['spec-draft-n-min','0'],['log-verbosity','4'],['device','CUDA3,CUDA0'],['fit','off']],
    'reported combined token is normalized without swallowing its neighbors');
is_deeply(VisLlama::Catalog::args_to_preset_options(['--chat-template-file "C:\\Model Files\\chat.jinja"']),
    [['chat-template-file','C:\\Model Files\\chat.jinja']], 'combined quoted Windows path');
for my $args (['--log-verbosity 4 --no-warmup'],['--custom "unclosed']) {
    eval { VisLlama::Catalog::args_to_preset_options($args) };ok($@,'ambiguous combined input rejected');
}
my $dir=tempdir(CLEANUP=>1);
my $ini="$dir/working.ini";
open my $fh,'>',$ini or die $!;print $fh 'working configuration';close $fh;
my $bad=[{enabled=>1,build=>'test',alias=>'test',options=>[['log-verbosity 4','true']]}];
eval { VisLlama::Catalog::write_router_ini_for_build($bad,'test',$ini) };
my $error=$@;like($error,qr/Invalid saved model options/,'legacy corrupt option rejected before opening INI');
open $fh,'<',$ini or die $!;is(do {local $/;<$fh>},'working configuration','existing INI not truncated');close $fh;
{
    no warnings 'redefine';
    local *VisLlama::Catalog::router_paths=sub { die 'Should not reach disk write'; };
    eval { VisLlama::Catalog::save_router_presets($bad) };
    like($@,qr/Invalid saved model options/,'save preflights before any paths, catalog writes or synchronization');
    local *VisLlama::Errors::report=sub { 'test-reference' };
    my $public=VisLlama::Errors::public_error($error);
    is($public->{message},'Invalid saved model options. Open the model editor and correct its extra arguments.','safe actionable error without source location');
}
done_testing();
