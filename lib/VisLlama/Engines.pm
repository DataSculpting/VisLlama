package VisLlama::Engines;
# GPL-3.0-only. Optional engine builds and instance lifecycle; llama.cpp stays built in.
use strict;
use warnings;
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use File::Spec;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Cwd qw(abs_path getcwd);
use Time::HiRes qw(time);
use VisLlama::Context qw(%CFG $STATE);
use VisLlama::Paths ();
use VisLlama::Config ();
use VisLlama::Storage ();
use VisLlama::Engine::Registry ();
use VisLlama::Engine::Plan ();
use VisLlama::Engine::Discovery ();
use VisLlama::Command ();
use VisLlama::Platform ();
use VisLlama::ProcessState ();
use VisLlama::Lifecycle ();
use VisLlama::Errors ();
VisLlama::Errors::register_validation(
    q{Enter a model alias using letters, numbers, dots, underscores, hyphens, or colons. Spaces and slashes aren't allowed.},
    q{Engine compatibility check failed. Check the registered installation and executable in Settings > Manage builds. For Strata, select the prepared Python interpreter, not strata.exe. See Logs / Diagnostics for details.},
    'Review and register the changed engine definition first',
    'Registered build changed; register its current revision again',
    'Some library folders are missing. Review Native library folders before discovery.',
    'Library folders must be a list of directory paths',
    'The model inference executable differs from this build. Select the matching build before discovering options.',
    'Library folders differ from the discovery environment. Discover options from this model again.',
    'Model path is missing',
    'Use comma-separated whole numbers, or auto where supported.',
    'Prepared model path does not match the selected model format.',
    'Engine configuration is incomplete. Fill required fields and check required files.',
    'Selected engine options are unavailable. Discover capabilities or review inactive settings before loading.',
    'Engine capability discovery failed. Check the selected executable and Logs / Diagnostics.',
    'Engine definition changed; refresh before saving',
    'Stop Router before editing this engine definition',
    'Stop Router before changing a model engine type',
    'Review the selected engine settings before replacing this preset',
    'Native executable differs from the discovered build. Update its native executable in Manage builds and discover again.',
);
sub external {ref($_[0]) eq 'HASH' && length($_[0]{engine}//'') && $_[0]{engine} ne 'llamacpp'}
sub group_key {my ($p)=@_;return 'extension:'.$p->{alias} if external($p);require VisLlama::GPUIsolation;return VisLlama::GPUIsolation::group_key($p)}
sub build_path {File::Spec->catfile(VisLlama::Paths::presets_dir(),'engine-builds.json')}
sub builds {VisLlama::Config::read_json_file(build_path(),[])}
sub build {my ($id)=@_;my ($b)=grep {$_->{id} eq ($id//'')} @{builds()};die 'Unknown extension build' unless $b;return $b}
sub definition {VisLlama::Engine::Registry::get($_[0]{engine})}
sub fingerprint {
    my ($b)=@_;my @files=($b->{executable});push @files,$b->{runtime_executable} if length($b->{runtime_executable}//'');
    my $d=definition($b);
    for my $relative (@{$d->{fingerprint_files}||[]}) {my $file=File::Spec->catfile($b->{root},split m{/},$relative);die 'Fingerprint file is outside registered build root' unless VisLlama::Paths::canonical_under($file,$b->{root});push @files,$file;}
    my @parts;
    for my $p (@files) {open my $fh,'<:raw',$p or die 'Registered executable is unavailable';my $sha=Digest::SHA->new(256);$sha->addfile($fh);close $fh;push @parts,$p,$sha->hexdigest;}
    return sha256_hex(join("\0",$b->{root},@parts,(@{$b->{runtime_library_dirs}||[]}?JSON::PP->new->canonical->encode($b->{runtime_library_dirs}):())));
}
sub save_build {
    my ($r)=@_;my $d=VisLlama::Engine::Registry::get($r->{engine});
    die 'Select this definition explicitly before registering the build' unless ($r->{definition_digest}//'') eq $d->{digest};
    die 'Build name is required' unless VisLlama::Engine::Registry::scalar_text($r->{name}) && length($r->{name});
    my $root=abs_path($r->{root}//'');my $exe=abs_path($r->{executable}//'');
    die 'Select an existing install root and executable' unless $root && -d $root && $exe && -f $exe && ($^O eq 'MSWin32' || -x $exe);
    die 'Register an executable or interpreter, not a shell launcher' if $exe =~ /\.(?:bat|cmd|ps1|sh)$/i;
    my $platform=$^O eq 'MSWin32'?'windows':$^O;
    die 'Definition does not support this operating system' unless grep {$_ eq $platform} @{$d->{platforms}};
    my $items=builds();my $id=$r->{id};
    if ($id) {my $old=build($id);die 'A build cannot change engine family; register another build' unless $old->{engine} eq $d->{id};
        die 'Stop Router before changing a registered build' if grep {($_->{build}//'') eq $id} values %{$STATE->{router_engines}||{}};
    } else {$id='engine-'.substr(sha256_hex(time().rand().$$),0,20);}
    my $native=$r->{runtime_executable}//'';if(length $native){$native=abs_path($native);die 'Select an existing native engine executable' unless $native && -f $native && ($^O eq 'MSWin32'||-x $native);die 'Select a native executable, not a shell launcher' if $native =~ /\.(?:bat|cmd|ps1|sh)$/i;}
    my $dirs=$r->{runtime_library_dirs}||[];die 'Native library directories must be an array of existing directories' unless ref($dirs) eq 'ARRAY' && !grep {!defined($_)||ref($_)||!-d $_} @$dirs;
    my $b={runtime_library_dirs=>$dirs,runtime_executable=>$native,id=>$id,name=>$r->{name},engine=>$d->{id},root=>$root,executable=>$exe,definition_digest=>$d->{digest},allow_concurrent=>$r->{allow_concurrent}?JSON::PP::true:JSON::PP::false};
    $b->{fingerprint}=fingerprint($b);
    @$items=grep {$_->{id} ne $id} @$items;push @$items,$b;
    VisLlama::Config::write_json_file_ascii(build_path(),$items);return $b;
}
sub delete_build {
    my ($id)=@_;require VisLlama::Catalog;
    die 'Reassign or delete model presets using this build first' if grep {($_->{build}//'') eq $id} @{VisLlama::Catalog::load_router_presets()};
    die 'Stop Router before removing this build' if grep {($_->{build}//'') eq $id} values %{$STATE->{router_engines}||{}};
    VisLlama::Config::write_json_file_ascii(build_path(),[grep {$_->{id} ne $id} @{builds()}]);
}
sub probe {
    my ($id)=@_;my $b=build($id);my $d=definition($b);die 'Review and register the changed engine definition first' unless definition_compatible($b,$d);
    die 'This definition has no approved probe; use its documented build contract' unless $d->{probe};
    my $argv=VisLlama::Engine::Plan::expand($d->{probe}{argv},{executable=>$b->{executable},root=>$b->{root}});
    my $cwd=getcwd();my ($out,$err,$exit,$failure);
    eval {chdir $b->{root} or die 'Cannot enter build directory';local $VisLlama::Command::TIMEOUT=$d->{probe}{timeout};local $VisLlama::Command::LIMIT=1048576;
        $out=VisLlama::Command::capture(1,@$argv);$exit=$?;$err=$VisLlama::Command::LAST_STDERR;1} or $failure=$@;
    chdir $cwd or die 'Cannot restore working directory';
    my @missing=grep {my $flag=quotemeta($_);(($out//'')."\n".($err//'')) !~ /(?<![\w-])$flag(?![\w-])/} @{$d->{probe}{required_flags}};
    my $record={fingerprint=>fingerprint($b),definition_digest=>$d->{digest},at=>time(),stdout=>$out,stderr=>$err,exit=>$exit,failure=>$failure,missing_flags=>\@missing,compatible=>(!$failure && !$exit && !@missing)?JSON::PP::true:JSON::PP::false};
    my $path=File::Spec->catfile(VisLlama::Paths::presets_dir(),$id.'-probe.json');VisLlama::Config::write_json_file_ascii($path,$record);
    $record->{reference}=VisLlama::Errors::report($failure||'Engine probe did not satisfy required flags: '.join(', ',@missing).' '.($err//''),'process_error') unless $record->{compatible};
    return {compatible=>$record->{compatible},missing_flags=>\@missing,reference=>$record->{reference},fingerprint=>$record->{fingerprint}};
}
sub definition_compatible {my ($b,$d)=@_;return $b->{definition_digest} eq $d->{digest} || grep {$_ eq $b->{definition_digest}} @{$d->{compatible_definition_digests}||[]};}
sub field_selected {my ($p,$f)=@_;return grep {exists($p->{settings}{$_}) && defined($p->{settings}{$_})} ($f->{key},@{$f->{legacy_keys}||[]});}
sub capabilities {my ($b)=@_;VisLlama::Engine::Discovery::effective($b,definition($b))}
sub discover {my ($id,$p)=@_;my $b=build($id);my $d=definition($b);die 'Review and register the changed engine definition first' unless definition_compatible($b,$d);my $libraries=VisLlama::Engine::Libraries::resolve($b,$d,$p);die 'Some library folders are missing. Review Native library folders before discovery.' if @{$libraries->{missing}};my $result=eval {VisLlama::Engine::Discovery::run($b,$d,$p)};die 'Engine capability discovery failed. Check the selected executable and Logs / Diagnostics.'.chr(10).$@ if $@;return $result;}
sub validate_preset {
    my ($p,$launch)=@_;my $b=build($p->{build});my $d=capabilities($b);
    die 'Preset and build engine types disagree' unless $p->{engine} eq $b->{engine};
    die 'Model path is missing' unless defined($p->{model}) && (-f $p->{model} || -d $p->{model});
    my $plan=VisLlama::Engine::Plan::render($d,$b,$p,'preview-instance',8081);
    my %available;for my $f (@{$d->{fields}}){$available{$_}=(!exists($f->{available})||$f->{available}) for ($f->{key},@{$f->{legacy_keys}||[]});}
    die 'Selected engine options are unavailable. Discover capabilities or review inactive settings before loading.' if $launch && ((grep {exists($_->{available}) && !$_->{available} && field_selected($p,$_)} @{$d->{fields}}) || (grep {exists($p->{settings}{$_}) && defined($p->{settings}{$_}) && !$available{$_}} @{$p->{capability_keys}||[]}));
    if ($launch) {
        my %native_probes=map {$_->{id}=>1} grep {$_->{argv}[0] eq '${runtime_executable}'} @{$d->{discovery}||[]};
        if ($d->{runtime_executable_path} && grep {$native_probes{$_->{support}{probe}//''} && !$_->{support}{advisory} && field_selected($p,$_)} @{$d->{fields}}) {
            if ($d->{capabilities}{library_digest}) {my $l=VisLlama::Engine::Libraries::resolve($b,$d,$p);die 'Library folders differ from the discovery environment. Discover options from this model again.' unless VisLlama::Engine::Libraries::digest($l) eq $d->{capabilities}{library_digest};}
            my $exe=abs_path(VisLlama::Engine::Plan::get_path($plan->{config},$d->{runtime_executable_path})//'');die 'Native executable differs from the discovered build. Update its native executable in Manage builds and discover again.' unless $exe && $exe eq ($b->{runtime_executable}//'');
        }
        die 'Review and register the changed engine definition first' unless definition_compatible($b,$d);
        if ($d->{probe}) {
            my $r=VisLlama::Config::read_json_file(File::Spec->catfile(VisLlama::Paths::presets_dir(),$b->{id}.'-probe.json'),{});
            unless ($r->{compatible} && ($r->{fingerprint}//'') eq fingerprint($b) && ($r->{definition_digest}//'') eq $d->{digest}) {
                my $check=probe($b->{id});
                die q{Engine compatibility check failed. Check the registered installation and executable in Settings > Manage builds. For Strata, select the prepared Python interpreter, not strata.exe. See Logs / Diagnostics for details.} unless $check->{compatible};
            }
        } else {die 'Registered build changed; register its current revision again' unless $b->{fingerprint} eq fingerprint($b);}
    }
    return ($d,$b);
}
sub check_replacement {
    my ($r,$old,$engine)=@_;return unless $old && ($old->{engine}||'llamacpp') ne $engine;
    die 'Review the selected engine settings before replacing this preset' unless $r->{replace_engine};
    die 'Stop Router before changing a model engine type' if $STATE->{proc} || $STATE->{proxy_proc} || keys %{$STATE->{router_engines}||{}};
}
sub save_preset {
    my ($r)=@_;require VisLlama::Catalog;
    die q{Enter a model alias using letters, numbers, dots, underscores, hyphens, or colons. Spaces and slashes aren't allowed.} unless ($r->{alias}//'') =~ /\A[A-Za-z0-9._:-]+\z/;
    my $b=build($r->{build});my $items=VisLlama::Catalog::load_router_presets();
    my ($old)=grep {$_->{alias} eq ($r->{original_alias}//'')} @$items;
    check_replacement($r,$old,$b->{engine});
    die 'Confirm overwriting the existing alias' if grep {$_->{alias} eq $r->{alias} && $_->{alias} ne ($r->{original_alias}//'') && !$r->{overwrite}} @$items;
    for my $target (grep {$_->{alias} eq $r->{alias}} @$items) {check_replacement($r,$target,$b->{engine});}
    my $p={config_mode=>$r->{config_mode}||($old?$old->{config_mode}:undef)||'import',alias=>$r->{alias},engine=>$b->{engine},build=>$b->{id},model=>$r->{model},settings=>$r->{settings}||{},native_config=>$r->{native_config}||{},
        stop_timeout=>$old?int($old->{stop_timeout}||10):10,enabled=>$old?$old->{enabled}:JSON::PP::true,load_on_startup=>$old?$old->{load_on_startup}:JSON::PP::false,ui=>{},options=>[],saved_at=>scalar localtime};
    my $effective=capabilities($b);my %base=map {$_->{key}=>1} @{definition($b)->{fields}};my %capability_keys;
    for my $key (@{($old && ($old->{engine}//'') eq $b->{engine}) ? ($old->{capability_keys}||[]) : []},@{$r->{capability_keys}||[]},map {$_->{key}} grep {!$base{$_->{key}}} @{$effective->{fields}}) {die 'Invalid saved capability key' unless VisLlama::Engine::Registry::id($key);$capability_keys{$key}=1 if exists($p->{settings}{$key});}
    $p->{capability_keys}=[sort keys %capability_keys];
    $p->{native_config_hash}=sha256_hex(JSON::PP->new->canonical->encode($p->{native_config}));
    validate_preset($p,0);
    my $inserted=0;my @new;
    for my $item (@$items) {if ($item->{alias} eq ($r->{original_alias}//'') || $item->{alias} eq $p->{alias}) {push @new,$p unless $inserted++;} else {push @new,$item;}}
    push @new,$p unless $inserted;VisLlama::Catalog::save_router_presets(\@new);return \@new;
}
sub sensitive { $_[0] =~ /(?:\A|[_-])(?:api[_-]?key|access[_-]?token|auth(?:orization)?|secret|password|credential)s?\z/i }
sub redact {
    my ($x)=@_;
    return {map {($_=>(sensitive($_)?'[redacted]':redact($x->{$_})))} keys %$x} if ref($x) eq 'HASH';
    if (ref($x) eq 'ARRAY') {
        my @out;my $hide=0;
        for my $v (@$x) {
            if ($hide) {push @out,'[redacted]';$hide=0;next;}
            if (!ref($v) && defined($v) && $v =~ /\A--([^=]+)(?:=(.*))?\z/ && sensitive($1)) {
                if (defined $2) {push @out,'--'.$1.'=[redacted]';} else {push @out,$v;$hide=1;}
            } else {push @out,redact($v);}
        }
        return \@out;
    }
    return $x;
}
sub preview {
    my ($r)=@_;my $b=build($r->{build});my $d=capabilities($b);
    return redact(VisLlama::Engine::Plan::render($d,$b,{%$r,settings=>$r->{settings}||{}},'<instance>',8081));
}
sub http_json {
    my ($eng,$path)=@_;require HTTP::Tiny;
    my $r=HTTP::Tiny->new(timeout=>1,max_size=>1048576,no_proxy=>['127.0.0.1','localhost'])->get('http://127.0.0.1:'.$eng->{port}.$path);
    die 'Engine readiness request failed' unless $r->{success};return JSON::PP::decode_json($r->{content});
}
sub status {
    my ($eng)=@_;return $eng->{extension_failed}?'failed':'unloaded' unless $eng->{proc};
    unless (VisLlama::ProcessState::router_engine_running($eng)) {$eng->{extension_failed}=1;return 'failed';}
    my $rule=$eng->{plan}{readiness};my $json=eval {http_json($eng,$rule->{path})};
    my $ready=!$@ && ref($json) eq 'HASH';
    if ($ready) {for my $k (keys %{$rule->{equals}}) {$ready=0 unless exists($json->{$k}) && JSON::PP->new->canonical->encode($json->{$k}) eq JSON::PP->new->canonical->encode($rule->{equals}{$k});}}
    $eng->{ready}=$ready?1:0;$eng->{ready_checked_at}=time();
    if ($ready) {
        my $models=eval {http_json($eng,'/v1/models')};
        $ready=0 unless ref($models) eq 'HASH' && ref($models->{data}) eq 'ARRAY' && grep {ref($_) eq 'HASH' && ($_->{id}//'') eq $eng->{models}[0]} @{$models->{data}};
        $eng->{ready}=$ready?1:0;
    }
    return $ready?'loaded':'loading';
}
sub unload {
    my ($eng)=@_;
    die 'Engine stop is unconfirmed; ownership retained. Retry Stop.' unless VisLlama::ProcessState::stop_owned_process($eng->{proc},$eng->{pid},'extension engine');
    delete @{$eng}{qw(proc pid extension_failed)};$eng->{ready}=0;return {};
}
sub load {
    my ($alias,$eng)=@_;require VisLlama::Catalog;
    return {} if status($eng) eq 'loaded';die 'Engine is still loading; wait or unload it' if $eng->{proc};
    my ($p)=grep {$_->{alias} eq $alias && $_->{enabled}} @{VisLlama::Catalog::load_router_presets()};die 'Enabled model preset missing' unless $p;
    die 'Restart Router after changing the engine build' unless $p->{build} eq $eng->{build};
    my ($d,$b)=validate_preset($p,1);
    if ($d->{concurrency} eq 'single-instance' || ($d->{concurrency} eq 'unverified' && !$b->{allow_concurrent})) {die 'Concurrent instances are unverified for this definition; unload its other model first' if grep {$_ != $eng && ($_->{engine}//'') eq $d->{id} && $_->{proc}} values %{$STATE->{router_engines}||$STATE->{starting_engines}||{}};}
    my $base=File::Spec->catdir(VisLlama::Paths::app_base_dir(),'logs','instances');make_path($base,{mode=>0700});
    my $dir=tempdir('engine-XXXXXXXX',DIR=>$base,CLEANUP=>0);chmod 0700,$dir;
    my $plan=VisLlama::Engine::Plan::render($d,$b,$p,File::Spec->rel2abs($dir),$eng->{port});
    VisLlama::Config::write_json_file_ascii($plan->{config_path},$plan->{config}) if $d->{driver} eq 'native-json';
    VisLlama::Config::write_json_file_ascii(File::Spec->catfile($dir,'launch.json'),{plan=>$plan,preset=>$p,build_fingerprint=>fingerprint($b)});
    my $launcher=File::Spec->catfile($dir,'launch'.VisLlama::Platform::launcher_suffix());my $exit=File::Spec->catfile($dir,'exitcode');
    if (VisLlama::Platform::windows()) {
        require VisLlama::Util;
        open my $fh,'>:encoding(UTF-8)',$launcher or die 'Cannot write engine launcher';
        print {$fh} "\$ErrorActionPreference = 'Stop'\n";
        for my $k (sort keys %{$plan->{env}}) {print {$fh} '$env:'.$k.' = '.VisLlama::Util::ps_quote($plan->{env}{$k})."\n";}
        print {$fh} '& '.join(' ',map {VisLlama::Util::ps_quote($_)} ($plan->{exe},@{$plan->{args}})).' >> '.VisLlama::Util::ps_quote($plan->{log})." 2>&1\n";
        print {$fh} 'Set-Content -LiteralPath '.VisLlama::Util::ps_quote($exit).' -Value $LASTEXITCODE -Encoding ASCII'."\n";close $fh;
    } else {VisLlama::Platform::write_spec($launcher,$plan->{exe},$plan->{args},$plan->{cwd},$plan->{log},$exit,undef,$plan->{env});}
    delete $eng->{extension_failed};
    $eng->{plan}=$plan;$eng->{log_file}=$plan->{log};$eng->{exit_code_file}=$exit;
    $eng->{proc}=VisLlama::Platform::launch($launcher,$plan->{cwd});$eng->{pid}=$eng->{proc}->GetProcessID();
    my $token=VisLlama::Lifecycle::token();my $until=time()+300;
    while (time()<$until) {VisLlama::Lifecycle::checkpoint($token);my $s=status($eng);return {} if $s eq 'loaded';die 'Engine exited before model readiness; see private launch logs' if $s eq 'failed';select undef,undef,undef,0.25;}
    die 'Engine model readiness timed out; process remains owned for Stop';
}
sub dispatch {
    my ($eng,$method,$path,$body)=@_;
    return unload($eng) if $method eq 'POST' && $path eq '/models/unload';
    return load($body->{model},$eng) if $method eq 'POST' && $path eq '/models/load';
    return {data=>[{id=>$eng->{models}[0],status=>{value=>status($eng),args=>[]}}]} if $method eq 'GET' && $path =~ m{^/v1/models};
    die 'Unsupported engine management operation';
}
1;
