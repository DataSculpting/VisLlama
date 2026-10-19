package VisLlama::GPUProviders;

# Optional system CLI discovery. One bounded step runs between control requests;
# stats readers only consume snapshots. Missing tools never gate model loading.
use strict;
use warnings;
use File::Spec;
use Cwd qw(abs_path getcwd);
use Time::HiRes qw(time);
use JSON::PP ();
use VisLlama::Command ();
use VisLlama::GPUParsers ();
use VisLlama::Errors ();
use VisLlama::Context qw($STATE);
our $OS=$^O;
our $NOW=sub {time()};
our $RESOLVER;
our $RUNNER;
my (@PROVIDERS,$INITIALIZED,$LAST_REFRESH,$CURSOR);
my ($DISCOVERY_SPENT,$DISCOVERY_EPOCH);
our $BUSY;
my %REASON=(not_found=>'Tool not installed or not on an explicit search path.',pending=>'Checking installed tool capabilities.',
    no_devices=>'Tool reported no supported GPUs.',permission_denied=>'GPU tool access denied for the account running VisLlama.',
    timed_out=>'GPU tool exceeded its probe deadline.',execution_failed=>'GPU tool could not execute successfully.',
    unsupported_schema=>'Installed GPU tool output or query interface is unsupported.',
    unsupported_environment=>'Optional GPU tools are not enabled in this environment.',
    inventory_only=>'GPUs were identified, but no current sensor readings are available.',
    monitoring_ready=>'GPU monitoring is available.',monitoring_partial=>'Some GPU measurements are unavailable.',
    deferred=>'Probe deferred after its discovery budget was exhausted.',sample_stale=>'The last sensor sample is stale; awaiting the next bounded refresh.');

sub now {$NOW->()}
sub reset { @PROVIDERS=();$INITIALIZED=0;$BUSY=0;$LAST_REFRESH=undef;$CURSOR=0;$DISCOVERY_SPENT=0;$DISCOVERY_EPOCH=now(); }
sub environment {
    return 'unsupported' unless $OS eq 'linux' || $OS eq 'MSWin32';
    return 'wsl' if $OS eq 'linux' && (length($ENV{WSL_INTEROP}//'') || length($ENV{WSL_DISTRO_NAME}//''));
    if ($OS eq 'linux' && open(my $fh,'<','/proc/sys/kernel/osrelease')) {
        my $v=<$fh>//'';close $fh;return 'wsl' if $v =~ /microsoft/i;
    }
    return $OS eq 'MSWin32'?'windows':'linux';
}
sub resolve {
    my ($name)=@_;return $RESOLVER->($name) if $RESOLVER;
    my $windows=$OS eq 'MSWin32';my @dirs=split($windows?qr/;/:qr/:/,$ENV{PATH}//'');
    if (!$windows && $name ne 'xpu-smi') {
        push @dirs,'/opt/rocm/bin','/opt/rocm/libexec/rocm_smi';
        # Bounded, named SDK roots only. Never recursively search model drives.
        if (opendir(my $dh,'/opt')) {
            my @roots=sort grep {/\Arocm[-\d.]*\z/} readdir($dh);closedir $dh;
            push @dirs,map {"/opt/$_/bin"} @roots[0..($#roots<7?$#roots:7)] if @roots;
        }
        if (opendir(my $dh,'/opt/rocm')) {
            my @roots=sort grep {/\Acore-\d+\.\d+(?:\.\d+)?\z/} readdir($dh);closedir $dh;
            push @dirs,map {"/opt/rocm/$_/bin"} @roots[0..($#roots<7?$#roots:7)] if @roots;
        }
    }
    my %seen;my $cwd=abs_path(getcwd());
    for my $d (@dirs) {
        $d =~ s/^"(.*)"$/$1/;next unless File::Spec->file_name_is_absolute($d);
        my $directory=abs_path($d);next unless defined($directory) && -d $directory;
        next if ($windows?lc($directory):$directory) eq ($windows?lc($cwd):$cwd);
        next if $seen{$windows?lc($directory):$directory}++;
        my $p=File::Spec->catfile($directory,$name.($windows?'.exe':''));
        next unless -f $p && ($windows || -x $p);
        return abs_path($p);
    }
    return undef;
}
sub initialize {
    return if $INITIALIZED;$INITIALIZED=1;$DISCOVERY_SPENT=0;$DISCOVERY_EPOCH=now();
    my $env=environment();
    for my $pair (['amd-smi','AMD'],['rocm-smi','AMD'],['xpu-smi','Intel']) {
        push @PROVIDERS,{id=>$pair->[0],vendor=>$pair->[1],stage=>'find',status=>'pending',due=>0,rows=>[],failures=>0,environment=>$env,generation=>0};
    }
}
sub note {
    my ($p,$status)=@_;$p->{status}=$status;
    if (($p->{logged_status}//'') ne $status) {
        $p->{logged_status}=$status;
        # Literal statuses only in operational output; raw records stay private.
        warn 'VisLlama GPU provider '.$p->{id}.': '.$status."\n";
    }
}
sub failed {
    my ($p,$detail)=@_;my $kind=$detail =~ /permission denied|access (?:is )?denied|insufficient permissions/i?'permission_denied':
        $detail =~ /timed out/i?'timed_out':$detail =~ /schema|inventory changed|UUID changed|Malformed|incomplete device|unsupported query/i?'unsupported_schema':'execution_failed';
    $p->{reference}=VisLlama::Errors::report('GPU provider '.$p->{id}.' stage '.$p->{stage}.' at '.($p->{path}//'not resolved')."\n".$detail,'telemetry_error');
    note($p,$kind);$p->{rows}=[];$p->{sample_at}=undef;
    my @backoff=(5,15,60);$p->{due}=now()+$backoff[$p->{failures}<2?$p->{failures}:2];$p->{failures}++;
    $p->{stage}='find';delete @{$p}{qw(inventory static fields)};
}
sub execute {
    my ($p,$timeout,@args)=@_;
    my $start=now();my ($text,$exit,$stderr);
    my $ok=eval {
        if ($RUNNER) {($text,$exit,$stderr)=$RUNNER->($p->{path},$timeout,@args);}
        else {
            local $VisLlama::Command::TIMEOUT=$timeout;
            local $VisLlama::Command::LIMIT=1024*1024;
            $text=VisLlama::Command::capture(1,$p->{path},@args);$exit=$?;$stderr=$VisLlama::Command::LAST_STDERR;
        }
        1;
    };
    my $failure=$@;
    # Timeouts/cancellation consume the budget too, even though capture throws
    # before returning an exit status. Never make failed probes free retries.
    $p->{spent}+=now()-$start;
    $DISCOVERY_SPENT+=now()-$start if $p->{discovery};
    die 'GPU tool probe ['.join(' ',@args).'] failed: '.$failure unless $ok;
    die 'GPU tool command failed ['.join(' ',@args).'] ('.($exit//0).'): '.($stderr//'').' '.($text//'') if $exit;
    return $text;
}
sub request_refresh {
    initialize();return if defined($LAST_REFRESH) && now()-$LAST_REFRESH<2;
    $LAST_REFRESH=now();$DISCOVERY_SPENT=0;$DISCOVERY_EPOCH=now();
    for my $p (@PROVIDERS) {$p->{stage}='find';$p->{due}=0;$p->{spent}=0;$p->{failures}=0;}
}
sub measurement_status {
    my ($rows)=@_;return 'no_devices' unless @$rows;
    my @dynamic=qw(memory_used_mib temperature_c fan_percent utilization_percent power_w);
    return 'inventory_only' unless grep {my $r=$_;grep {defined($r->{$_})} @dynamic} @$rows;
    return (grep {my $r=$_;grep {!defined($r->{$_})} @VisLlama::GPUParsers::MEASUREMENTS} @$rows)?'monitoring_partial':'monitoring_ready';
}
sub step {
    my ($p)=@_;my $stage=$p->{stage};
    if ($stage eq 'find') {
        $p->{spent}=0;$p->{discovery}=1;$p->{generation}++;delete @{$p}{qw(reference static fields inventory)};
        if ($p->{environment} eq 'wsl' || $p->{environment} eq 'unsupported') {note($p,'unsupported_environment');$p->{rows}=[];$p->{due}=now()+60;return;}
        $p->{path}=resolve($p->{id});
        if (!$p->{path}) {note($p,'not_found');$p->{rows}=[];$p->{due}=now()+60;return;}
        $p->{stage}='help';$p->{due}=0;note($p,'pending');return;
    }
    if ($p->{discovery} && ($p->{spent}//0)>=15) {note($p,'deferred');$p->{due}=now()+60;$p->{stage}='find';return;}
    if ($stage eq 'help') {
        $p->{help}=execute($p,3,'--help');
        my $valid=$p->{id} eq 'amd-smi'?$p->{help} =~ /\blist\b/ && $p->{help} =~ /\bmetric\b/:
            $p->{id} eq 'rocm-smi'?$p->{help} =~ /--showmeminfo/:$p->{help} =~ /\bdiscovery\b/ && $p->{help} =~ /\bstats\b/;
        die 'Unsupported query interface schema' unless $valid;
        $p->{stage}='version';
    } elsif ($stage eq 'version') {
        my $v=eval {execute($p,3,$p->{id} eq 'amd-smi'?'version':'--version')} // '';
        $p->{version}=$1 if $v =~ /\b(\d+\.\d+(?:\.[A-Za-z0-9._+-]+)?)\b/;
        $p->{stage}='inventory';
    } elsif ($stage eq 'inventory') {
        if ($p->{id} eq 'amd-smi') {$p->{inventory}=VisLlama::GPUParsers::amd_inventory(execute($p,5,'list','--json'));$p->{stage}='static';}
        elsif ($p->{id} eq 'rocm-smi') {$p->{inventory}=VisLlama::GPUParsers::rocm_inventory(execute($p,5,'--showproductname','--showuniqueid','--showbus','--json'));$p->{stage}='sample';}
        else {$p->{inventory}=VisLlama::GPUParsers::intel_inventory(execute($p,5,'discovery','-j'));$p->{stage}= $p->{help} =~ /--query-gpu/?'fields':'legacy';}
        if (!@{$p->{inventory}}) {$p->{rows}=[];note($p,'no_devices');$p->{stage}='find';$p->{due}=now()+60;return;}
        $p->{discovered_at}=now();
    } elsif ($stage eq 'static') {
        # Static properties are optional. A partial/unsupported static command
        # must not discard valid metric capabilities on the same device.
        my $raw=eval {execute($p,5,'static','--json')};
        $p->{static}=eval {VisLlama::GPUParsers::amd_rows($raw)}||[];
        $p->{stage}='metric_help';
    } elsif ($stage eq 'metric_help') {
        my $h=execute($p,3,'metric','--help');
        my @flags=grep {my $f=quotemeta($_);$h =~ /$f\b/} qw(--mem-usage --usage --power --temperature --fan);
        $p->{metric_flags}=\@flags;$p->{stage}='sample';
    } elsif ($stage eq 'fields') {
        my $raw=execute($p,3,'--query-gpu');
        my @fields=grep {my $f=quotemeta($_);$raw =~ /(?<![\w.])$f(?![\w.])/} @VisLlama::GPUParsers::INTEL_FIELDS;
        die 'Unsupported query field schema' unless grep {$_ eq 'index'} @fields;
        $p->{fields}=\@fields;$p->{stage}='sample';
    } elsif ($stage eq 'legacy') {
        $p->{legacy_index}=0;$p->{legacy_rows}=[];$p->{stage}=exists($p->{inventory}[0]{_tiles})?'legacy_sample':'legacy_detail';
    } elsif ($stage eq 'legacy_detail') {
        my $i=$p->{legacy_index};my $r=$p->{inventory}[$i];
        $p->{inventory}[$i]=VisLlama::GPUParsers::intel_detail($r,execute($p,5,'discovery','-d',"$r->{index}",'-j'));
        $p->{stage}='legacy_sample';
    } elsif ($stage eq 'legacy_sample') {
        my $r=$p->{inventory}[$p->{legacy_index}];
        push @{$p->{legacy_rows}},VisLlama::GPUParsers::intel_stats_sample($r,execute($p,5,'stats','-d',"$r->{index}",'-j'));
        if (++$p->{legacy_index}<@{$p->{inventory}}) {$p->{stage}=exists($p->{inventory}[$p->{legacy_index}]{_tiles})?'legacy_sample':'legacy_detail';}
        else {$p->{rows}=$p->{legacy_rows};publish($p);$p->{stage}=now()-($p->{discovered_at}//0)>=60?'find':'legacy';return;}
    } elsif ($stage eq 'sample') {
        my $rows;
        if ($p->{id} eq 'amd-smi') {$rows=VisLlama::GPUParsers::amd_sample($p->{inventory},$p->{static}||[],execute($p,5,'metric',@{$p->{metric_flags}||[]},'--json'));}
        elsif ($p->{id} eq 'rocm-smi') {$rows=VisLlama::GPUParsers::rocm_sample($p->{inventory},execute($p,5,'--showmeminfo','vram','--showuse','--showtemp','--showfan','--showpower','--json'));}
        else {$rows=VisLlama::GPUParsers::intel_sample($p->{inventory},$p->{fields},execute($p,5,'--query-gpu='.join(',',@{$p->{fields}}),'--format=csv,noheader,nounits'));}
        $p->{rows}=$rows;publish($p);
        $p->{stage}='find' if now()-($p->{discovered_at}//0)>=60;
        return;
    }
    $p->{due}=0;
}
sub publish {
    my ($p)=@_;$p->{sample_at}=now();$p->{sampled_at}=scalar localtime;$p->{failures}=0;delete $p->{reference};
    $p->{discovery}=0;note($p,measurement_status($p->{rows}));$p->{due}=now()+1.2;
}
# Called only from the application's idle loop, not a control/API operation.
# A local guard prevents nested lifecycle pumping from reentering discovery.
sub tick {
    initialize();return if $BUSY || $STATE->{active_operation};
    local $BUSY=1;
    if (now()-$DISCOVERY_EPOCH>=60) {$DISCOVERY_SPENT=0;$DISCOVERY_EPOCH=now();}
    for (1..scalar(@PROVIDERS)) {
        my $p=$PROVIDERS[$CURSOR++ % @PROVIDERS];next if now()<($p->{due}//0);
        if ($p->{discovery} && $DISCOVERY_SPENT>=30) {note($p,'deferred');$p->{stage}='find';$p->{due}=now()+60;next;}
        eval {step($p)};
        failed($p,$@) if $@;
        last;
    }
}
sub provider_status {
    my ($p)=@_;
    my $status=$p->{status};$status='sample_stale' if $status =~ /^monitoring_/ && defined($p->{sample_at}) && now()-$p->{sample_at}>5;
    return {id=>$p->{id},vendor=>$p->{vendor},status=>$status,message=>$REASON{$status}//'GPU provider unavailable.',
        version=>$p->{version},reference=>$p->{reference},device_count=>scalar(@{$p->{inventory}||[]}),
        missing_fields=>[grep {my $field=$_;!grep {defined($_->{$field})} @{$p->{rows}}} @VisLlama::GPUParsers::MEASUREMENTS],
        next_check_seconds=>($p->{due}//0)>now()?int($p->{due}-now()+0.999):0,
        environment=>$p->{environment},sampled_at=>$p->{sampled_at},
        identity_status=>'identity_unverified',explicit_placement_ready=>JSON::PP::false};
}
sub snapshot {
    my ($vendor)=@_;initialize();my (@rows,@statuses,%uuid,%bus);my $latest;
    my @inventory_only;
    for my $p (grep {$_->{vendor} eq $vendor} @PROVIDERS) {
        push @statuses,provider_status($p);
        next unless defined($p->{sample_at}) && now()-$p->{sample_at}<=5;
        for my $row (@{$p->{rows}}) {
            if (!grep {defined $row->{$_}} qw(memory_used_mib temperature_c fan_percent utilization_percent power_w)) {push @inventory_only,$row;next;}
            # Prefer AMD-SMI. A second provider contributes only devices proven
            # distinct from every selected record, never same-name guesses.
            if (@rows && $p->{id} eq 'rocm-smi') {
                next if !$row->{pci_bus_id} || grep {!$_->{pci_bus_id}} @rows;
                next if $bus{$row->{pci_bus_id}} || $row->{uuid} && $uuid{$row->{uuid}};
            }
            push @rows,{%$row,sample_age_seconds=>now()-$p->{sample_at},sampled_at=>$p->{sampled_at}};
            $bus{$row->{pci_bus_id}}=1 if $row->{pci_bus_id};$uuid{$row->{uuid}}=1 if $row->{uuid};
            $latest=$p->{sampled_at};
        }
    }
    @rows=grep {$_->{provider} eq $inventory_only[0]{provider}} @inventory_only if !@rows && @inventory_only;
    return {vendor=>$vendor,available=>@rows?JSON::PP::true:JSON::PP::false,gpus=>\@rows,sampled_at=>$latest,providers=>\@statuses};
}
1;
