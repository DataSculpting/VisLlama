# Follow editor-shaped arguments through actual save, disk catalog and Router
# INI generation. GPU probes must not run for Even split or Manual mode.
use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use VisLlama::API::Models ();
use VisLlama::Context qw(%CFG $STATE);
use VisLlama::Config ();
use VisLlama::Catalog ();

my $dir=tempdir(CLEANUP=>1);
my $model="$dir/model.gguf";
open my $fh,'>',$model or die $!;close $fh;
mkdir "$dir/presets" or die $!;
{
    no warnings 'redefine';
    local $CFG{builds}={test=>$dir};local $CFG{model_root}=$dir;local $STATE={};
    local *VisLlama::Paths::presets_dir=sub {"$dir/presets"};
    local *VisLlama::Paths::canonical_under=sub {1};
    local *VisLlama::GPUPlanner::gpu_plan_for_mode=sub {die 'Unexpected planner intervention'};
    my $reply;
    local *VisLlama::HTTP::json_response=sub {$reply=$_[2]};
    local *VisLlama::HTTP::fail_json=sub {die 'Save rejected: '.($_[1]//'')};
    my $request={alias=>'second',build=>'test',model=>$model,
        args=>['--tensor-split','1,1','--split-mode','layer','--device','CUDA1,CUDA2','--parallel','4'],
        ui=>{gpuPriority=>'even',tensorSplit=>'',devices=>['CUDA1','CUDA2']}};
    VisLlama::API::Models::handle(undef,'/api/router-preset-save',$request);
    ok($reply->{ok},'Even split saves with blank disabled manual field');
    my $saved=VisLlama::Catalog::load_router_presets()->[0];
    is_deeply([grep {$_->[0] eq 'tensor-split'} @{$saved->{options}}],[['tensor-split','1,1']],
        'Equal weights survive in saved catalog');
    is_deeply([grep {$_->[0] eq 'device'} @{$saved->{options}}],[['device','CUDA1,CUDA2']],
        'Exactly the two selected CUDA devices survive');
    is($saved->{ui}{tensorSplit},'','Disabled manual field remains unchanged');
    my $ini="$dir/even.ini";
    VisLlama::Catalog::write_router_ini_for_build([$saved],'test',$ini);
    open $fh,'<',$ini or die $!;my $text=do {local $/;<$fh>};close $fh;
    like($text,qr/^tensor-split = 1,1$/m,'Router INI retains equal split');
    like($text,qr/^device = CUDA1,CUDA2$/m,'Router INI restricts selected devices');
    like($text,qr/^split-mode = layer$/m,'Router INI retains layer split');
    unlike($text,qr/^(?:fit|no-fit|gpu-layers) =/m,'No calculated split or fitting override added');
    # The original manual reset behavior must remain intact on a mode switch.
    $request->{ui}{gpuPriority}='manual';
    VisLlama::API::Models::handle(undef,'/api/router-preset-save',$request);
    $saved=VisLlama::Catalog::load_router_presets()->[0];
    is_deeply([grep {$_->[0] eq 'tensor-split'} @{$saved->{options}}],[],
        'Manual blank still clears stale raw tensor split');
    $request->{ui}{tensorSplit}='2,1';$request->{args}[1]='2,1';
    VisLlama::API::Models::handle(undef,'/api/router-preset-save',$request);
    $saved=VisLlama::Catalog::load_router_presets()->[0];
    is_deeply([grep {$_->[0] eq 'tensor-split'} @{$saved->{options}}],[['tensor-split','2,1']],
        'Manual explicit weights remain unchanged');
}
done_testing();
