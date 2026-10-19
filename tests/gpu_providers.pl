use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);
use File::Spec;
use JSON::PP qw(decode_json encode_json);
use VisLlama::GPUProviders ();
use VisLlama::GPUParsers ();
use VisLlama::Context qw($STATE);
use VisLlama::Paths ();
sub fixture {open my $fh,'<:raw',"$RealBin/fixtures/gpu-providers/$_[0]" or die $!;local $/;return <$fh>}
my $tmp=tempdir(CLEANUP=>1);my $clock=100;my (@calls,@warnings);my $fail_amd=0;my $legacy=0;
no warnings 'redefine';
local *VisLlama::Paths::app_base_dir=sub {$tmp};
local $SIG{__WARN__}=sub {push @warnings,@_};
local $VisLlama::GPUProviders::NOW=sub {$clock};
local $VisLlama::GPUProviders::OS='linux';
local $ENV{WSL_INTEROP};local $ENV{WSL_DISTRO_NAME};
local $VisLlama::GPUProviders::RESOLVER=sub {'/installed tools/'.$_[0]};
local $VisLlama::GPUProviders::RUNNER=sub {
    my ($path,$timeout,@args)=@_;push @calls,[$path,$timeout,@args];
    return ('',256,'permission denied accessing GPU sensors') if $fail_amd && $path =~ /amd-smi$/;
    my $cmd=join(' ',@args);
    return ('list metric discovery stats --showmeminfo --json'.($legacy?'':' --query-gpu'),0,'') if $cmd eq '--help';
    return ('Tool version 2.0.0',0,'') if $cmd eq 'version' || $cmd eq '--version';
    return (fixture('amd-list.json'),0,'') if $cmd eq 'list --json';
    return (fixture('amd-static.json'),0,'') if $cmd eq 'static --json';
    return ('--mem-usage --usage --temperature --power --fan --json',0,'') if $cmd eq 'metric --help';
    return (fixture('amd-metric.json'),0,'') if $cmd =~ /^metric /;
    return (fixture('rocm-list.json'),0,'') if $cmd =~ /^--showproductname/;
    return (fixture('rocm-metric.json'),0,'') if $cmd =~ /^--showmeminfo/;
    return (fixture('intel-discovery.json'),0,'') if $cmd eq 'discovery -j';
    return (join(' ',@VisLlama::GPUParsers::INTEL_FIELDS),0,'') if $cmd eq '--query-gpu';
    return (fixture('intel-metric.csv'),0,'') if $cmd =~ /^--query-gpu=/;
    return (fixture('intel-detail.json'),0,'') if $cmd eq 'discovery -d 0 -j';
    return (fixture('intel-stats.json'),0,'') if $cmd eq 'stats -d 0 -j';
    die 'Unexpected command in fixture: '.$cmd;
};
sub ticks {for (1..$_[0]) {VisLlama::GPUProviders::tick();$clock+=0.1;}}
VisLlama::GPUProviders::reset();
my $snapshot=VisLlama::GPUProviders::snapshot('AMD');
is(scalar(@calls),0,'Stats snapshot never runs optional CLI probes');
is($snapshot->{providers}[0]{status},'pending','Startup is explicitly pending');
ticks(60);
$snapshot=VisLlama::GPUProviders::snapshot('AMD');
is(scalar(@{$snapshot->{gpus}}),2,'Primary AMD and distinct fallback GPU both selected');
is($snapshot->{gpus}[0]{provider},'amd-smi','Primary wins for overlapping BDF');
is($snapshot->{gpus}[1]{provider},'rocm-smi','Fallback supplies proven distinct card');
is($snapshot->{gpus}[1]{pci_bus_id},'00000000:0c:00.0','Provider ordinals never establish identity');
ok(!(grep {$_->{explicit_placement_ready}} @{$snapshot->{gpus}}),'No provider grants physical placement');
ok(VisLlama::GPUProviders::snapshot('Intel')->{available},'Mixed Intel monitoring available independently');
my $before=@calls;for (1..10) {VisLlama::GPUProviders::snapshot('AMD')}
is(scalar(@calls),$before,'Repeated API reads only consume caches');
local $STATE->{active_operation}={id=>'model-load'};
ticks(10);is(scalar(@calls),$before,'No provider work runs during lifecycle mutation');
$STATE->{active_operation}=undef;
$fail_amd=1;$clock+=2;ticks(10);
$snapshot=VisLlama::GPUProviders::snapshot('AMD');
is($snapshot->{providers}[0]{status},'permission_denied','Permission errors are actionable public statuses');
like($snapshot->{providers}[0]{reference},qr/^VL-/,'Private raw errors have correlated references');
ok(!exists($snapshot->{providers}[0]{resolved_path}),'Public provider status omits executable path');
is($snapshot->{gpus}[0]{provider},'rocm-smi','Working legacy provider remains available when primary fails');
my $raw=encode_json($snapshot);unlike($raw,qr/installed tools|GPU sensors/,'Raw paths and stderr never enter snapshots');
$before=@calls;ticks(5);ok(@calls-$before<=2,'Failed provider uses retry backoff rather than a retry per poll');
$fail_amd=0;VisLlama::GPUProviders::request_refresh();ticks(60);
is(VisLlama::GPUProviders::snapshot('AMD')->{gpus}[0]{provider},'amd-smi','Refresh recovers preferred provider');
my $stamp=$clock;$clock+=10;
is(scalar(@{VisLlama::GPUProviders::snapshot('Intel')->{gpus}}),0,'Old samples are not presented as current');
$clock=$stamp;
VisLlama::GPUProviders::reset();$legacy=1;ticks(60);
is(VisLlama::GPUProviders::snapshot('Intel')->{gpus}[0]{schema},'xpusmi-stats-json','Validated JSON fallback is separate from field CSV');
ok((grep {join(' ',@{$_}[2..$#$_]) eq 'stats -d 0 -j'} @calls),'Fallback requests only a discovered device ID');
VisLlama::GPUProviders::reset();
local $VisLlama::GPUProviders::RESOLVER=sub {undef};$before=@calls;ticks(20);
is(scalar(@calls),$before,'Missing tools never run a subprocess');
is(VisLlama::GPUProviders::snapshot('AMD')->{providers}[0]{status},'not_found','Missing tools are not API failures');
VisLlama::GPUProviders::reset();local $ENV{WSL_DISTRO_NAME}='Test guest';ticks(10);
is(VisLlama::GPUProviders::snapshot('Intel')->{providers}[0]{status},'unsupported_environment','WSL is not misreported as native Windows support');

{
 local $ENV{WSL_DISTRO_NAME};
 local $VisLlama::GPUProviders::RESOLVER=sub {'/installed tool'};
 my $attempts=0;
 local $VisLlama::GPUProviders::RUNNER=sub {my ($path,$timeout)=@_;$attempts++;$clock+=$timeout;die 'Native probe timed out'};
 VisLlama::GPUProviders::reset();ticks(40);
 my $states=VisLlama::GPUProviders::snapshot('AMD')->{providers};
 ok((grep {$_->{status} eq 'timed_out' || $_->{status} eq 'deferred'} @$states),'Probe timeout is classified without raw exceptions');
 cmp_ok($attempts,'<=',10,'Thrown timeouts consume the shared discovery budget');
}

# Exercise discovery against real files and explicit PATH directories, without
# depending on any vendor tool or on shell executable lookup behavior.
{
 local $VisLlama::GPUProviders::RESOLVER;local $ENV{PATH}=$tmp;
 my $file=File::Spec->catfile($tmp,'amd-smi');open my $fh,'>:raw',$file or die $!;print {$fh} "probe\n";close $fh;chmod 0755,$file;
 is(VisLlama::GPUProviders::resolve('amd-smi'),$file,'Explicit absolute PATH directory is searched');
 local $ENV{PATH}='.';is(VisLlama::GPUProviders::resolve('xpu-smi'),undef,'Relative PATH entries cannot execute a working-directory impostor');
}
done_testing();
