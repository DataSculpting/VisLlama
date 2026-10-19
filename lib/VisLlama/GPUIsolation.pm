package VisLlama::GPUIsolation;

# Runtime-only identities and namespace translation. Saved CUDA IDs remain in
# the selected build's original namespace; never substitute nvidia-smi indices.
use strict;
use warnings;
use File::Spec;
use File::Basename qw(dirname);
use JSON::PP qw(decode_json);
use Digest::SHA qw(sha1_hex);
use VisLlama::Builds ();
use VisLlama::Platform ();
use VisLlama::Util ();
use VisLlama::Context qw(%CFG);

sub fail { die 'GPU isolation could not be verified: '.($_[0]//'device identity or option validation failed'); }
sub bus_key {
    my ($s)=@_;
    return undef unless defined($s) && $s =~ /\A([0-9a-f]{4,8}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-7])\z/i;
    return join(':',map {hex($_)} ($1,$2,$3,$4));
}
sub canonical_key {
    my ($key)=@_;
    my %aliases=(dev=>'device',devd=>'spec-draft-device','device-draft'=>'spec-draft-device',
        mmdev=>'mmproj-device',ot=>'override-tensor');
    return $aliases{$key}//$key;
}
sub selection {
    my ($p)=@_;
    my %o=map {(canonical_key($_->[0]),$_->[1])} @{$p->{options}||[]};
    my $mode=$p->{ui}{gpuPriority}//'manual';
    my $raw=$mode=~/^priority/ ? join(',',@{$p->{ui}{devices}||[]}) : ($o{device}//'');
    return undef unless length $raw;
    
    my @main=$raw eq 'none' ? () : split /,/,$raw;
    my @draft=map {length($o{$_}//'') && $o{$_} ne 'none' ? split(/,/,$o{$_}) : ()} qw(spec-draft-device mmproj-device);
    return [] if $raw eq 'none' && !@draft;
    # Other backends retain native visibility. Mixed CUDA/non-CUDA placement is
    # not safely translatable and must not silently run with the wrong devices.
    return undef unless grep {/^CUDA/} (@main,@draft);
    fail() if grep {!/^CUDA\d+$/} @main;
    fail() if grep {!/^CUDA\d+$/} @draft;
    my %seen;my @all=grep {!$seen{$_}++} (@main,@draft);
    for my $key (qw(override-tensor ot tensor-buft-overrides)) {fail() if length($o{$key}//'')}
    return \@all;
}
# Extract only identity-affecting launch flags; direct mode also supports short
# engine options which do not belong to the Router INI converter.
sub options_from_args {
    my ($args)=@_;my @out;
    for(my $i=0;$i<@$args;$i++) {
        if ($args->[$i] =~ /^--?([A-Za-z][\w-]*)(?:=(.*))?$/) {
            my ($key,$inline)=(canonical_key($1),$2);
            next unless $key =~ /^(?:device|spec-draft-device|mmproj-device|override-tensor|tensor-buft-overrides)$/;
            my $value=defined($inline)?$inline:$args->[++$i];
            fail('Missing device or override argument value') unless defined $value;
            push @out,[$key,$value];
        }
    }
    return \@out;
}
sub group_key {
    my ($p)=@_;
    my $d=selection($p);my $build=$p->{build}//'';
    return $build unless defined $d;
    return $build.'@gpu-'.substr(sha1_hex(join(',',@$d)),0,16);
}
sub inventory {
    my ($build)=@_;
    my $exe=VisLlama::Builds::find_server_exe($CFG{builds}{$build}) or fail();
    fail('GGML_CUDA_DEVICES remaps backend device identities; remove it before using isolation') if length($ENV{GGML_CUDA_DEVICES}//'');
    my $json;
    if ($exe =~ m{\Adocker://}) {
        require VisLlama::Docker;$json=VisLlama::Docker::identity($exe);
    } elsif (VisLlama::Platform::windows()) {
    my $dir=dirname($exe);
    opendir my $dh,$dir or fail();
    my @runtime=map {File::Spec->rel2abs(File::Spec->catfile($dir,$_))} grep {/^cudart64.*\.dll$/i && -f File::Spec->catfile($dir,$_)} readdir $dh;
    closedir $dh;
    # Ambiguous runtimes need correction, never an ordinal/name-based guess.
    fail('Expected exactly one cudart64 runtime beside '.$exe) unless @runtime==1;
    my $script=File::Spec->rel2abs(File::Spec->catfile(dirname(__FILE__),'cuda-devices.ps1'));
    $json=VisLlama::Util::capture_command_stdout('powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script,'-Runtime',$runtime[0]);
    } else {
        require VisLlama::Platform::CUDA;
        $json=VisLlama::Platform::CUDA::probe($exe);
    }
    my $exit=$?;my $rows=eval {decode_json($json)};
    # The helper catches interop errors as JSON so the private diagnostic keeps
    # the failing operation/error code. Public responses still use a safe label.
    my $detail=ref($rows) eq 'HASH' ? ($rows->{error}//$json) : $json;
    fail('CUDA runtime identity probe failed (exit '.$exit.'): '.$detail) if $exit || ref($rows) ne 'ARRAY';
    my $raw=VisLlama::Util::capture_command(VisLlama::Platform::nvidia_smi(),'--query-gpu=uuid,pci.bus_id','--format=csv,noheader,nounits');
    fail('nvidia-smi identity query failed: '.$raw) if $?;
    my %uuid;
    for my $line (split /\r?\n/,$raw) {
        my ($id,$bus)=split /\s*,\s*/,$line;
        next unless defined($id) && $id =~ /^GPU-[a-f0-9-]+$/i;
        my $key=bus_key($bus);fail() unless defined $key;
        fail() if exists $uuid{$key};$uuid{$key}=$id;
    }
    my (%map,%seen_bus);
    for my $row (@$rows) {
        fail() unless ref($row) eq 'HASH' && ($row->{id}//'') =~ /^CUDA\d+$/;
        my $key=bus_key($row->{bus});fail() unless defined($key) && $uuid{$key};
        fail('Multiple CUDA devices share a physical bus; MIG requires separate support') if $seen_bus{$key}++;
        fail('CUDA UUID does not match its physical bus identity; MIG or virtual devices require separate support') unless lc($row->{uuid}//'') eq lc($uuid{$key});
        fail() if exists $map{$row->{id}};
        $map{$row->{id}}={uuid=>$uuid{$key},bus=>$key};
    }
    my $devices=VisLlama::Builds::parse_devices(VisLlama::Builds::checked_probe($exe,'--list-devices'));
    my @cuda=grep {($_->{id}//'') =~ /^CUDA\d+$/} @$devices;
    fail('Selected build CUDA enumeration does not match runtime identity map') unless @cuda==keys(%map) && !grep {!$map{$_->{id}}} @cuda;
    return \%map;
}
sub profile {
    my ($p,$maps)=@_;
    # The caller's map cache belongs to this launch, not to saved configuration.
    # Preserve selection order: it defines the child's local CUDA namespace.
    my $d=selection($p);return undef unless defined $d;
    my $map=@$d ? ($maps->{$p->{build}} ||= inventory($p->{build})) : {};
    my (@uuid,%translation);
    for my $id (@$d) {
        fail() unless $map->{$id};
        $translation{$id}='CUDA'.scalar(@uuid);push @uuid,$map->{$id}{uuid};
    }
    my $profile={devices=>$d,uuids=>\@uuid,map=>\%translation,visible=>join(',',@uuid)};
    $profile->{image_id}=VisLlama::Docker::resolve($CFG{builds}{$p->{build}})->{Id} if VisLlama::Docker::is_ref($CFG{builds}{$p->{build}});
    return $profile;
}
sub remap_options {
    my ($options,$profile)=@_;
    return $options unless $profile;
    my @out;
    for my $pair (@$options) {
        my ($key,$value)=@$pair;
        if (canonical_key($key) =~ /^(?:device|spec-draft-device|mmproj-device)$/) {
            if ($value ne 'none') {
                $value=join(',',map {fail() unless exists $profile->{map}{$_};$profile->{map}{$_}} split /,/,$value);
            }
        }
        # main-gpu is an index into the selected device list, not the global
        # CUDA ordinal; tensor-split weights also retain that list's order.
        push @out,[$key,$value];
    }
    return \@out;
}
sub remap_args {
    my ($args,$profile)=@_;return $args unless $profile;
    my @out=@$args;
    for(my $i=0;$i<@out;$i++) {
        next unless $out[$i] =~ /^(--?[A-Za-z][\w-]*)(?:=(.*))?$/;
        my ($flag,$inline)=($1,$2);my $key=$flag;$key =~ s/^--?//;
        next unless canonical_key($key) =~ /^(?:device|spec-draft-device|mmproj-device)$/;
        my $value=defined($inline)?$inline:$out[$i+1];
        fail('Missing launch device value') unless defined $value;
        my $mapped=remap_options([[$key,$value]],$profile)->[0][1];
        if(defined $inline) {$out[$i]="$flag=$mapped"} else {$out[++$i]=$mapped}
    }
    return \@out;
}
sub environment_line {
    my ($profile,$log)=@_;
    # Emit an assignment into the child launcher; do not mutate Perl's %ENV.
    # An absent profile preserves native visibility; an empty one hides CUDA.
    return '' unless $profile;
    my $text='$env:CUDA_VISIBLE_DEVICES = ' . VisLlama::Util::ps_quote($profile->{visible})."\n";
    if (defined $log) {
        my $note='VisLlama GPU mapping: '.(@{$profile->{devices}}
            ? join('; ',map {$profile->{devices}[$_].' -> CUDA'.$_.' ('.$profile->{uuids}[$_].')'} 0..$#{$profile->{devices}})
            : 'CPU only; no CUDA devices visible');
        $text.='Add-Content -LiteralPath '.VisLlama::Util::ps_quote($log).' -Value '.VisLlama::Util::ps_quote($note)." -Encoding Unicode\n";
    }
    return $text;
}
1;
