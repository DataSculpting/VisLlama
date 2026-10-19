package VisLlama::Docker;

# Linux-only llama.cpp runtime adapter. The public proxy, saved configuration and
# model files stay on the host. Never identify an owned container by a name alone.
use strict;
use warnings;
use JSON::PP ();
use File::Spec;
use File::Basename qw(dirname basename);
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Time::HiRes qw(time);
use VisLlama::Command ();
use VisLlama::Paths ();
use VisLlama::Context qw(%CFG $STATE);
our $CLI='docker';
my $OWNER=sha256_hex(join(':',$$,time(),rand()));
my (%INFO,%PROBES,%PENDING);
sub is_ref {defined($_[0]) && !ref($_[0]) && $_[0] =~ m{\Adocker://}}
sub image {my $v=$_[0];$v =~ s{\Adocker://}{};return $v}
sub validate_image {
    my ($v)=@_;die 'Docker images are supported only on Linux' unless $^O eq 'linux';
    die 'Enter an image reference, not a docker run command' unless defined($v) && length($v)<=512 && $v =~ /\A[A-Za-z0-9][A-Za-z0-9._\/:@-]*\z/;
    return 'docker://'.$v;
}
sub command {
    my ($stdout,@args)=@_;
    local $VisLlama::Command::TIMEOUT=30;
    my $text=VisLlama::Command::capture($stdout,$CLI,@args);my $exit=$?;
    die 'Docker command failed ('.$exit.'): '.$text.' '.$VisLlama::Command::LAST_STDERR if $exit;
    return $text;
}
sub decode {JSON::PP->new->decode($_[0])}
# A bounded Docker CLI probe can end before its container does. Name and label
# every ephemeral container, then recover its full ID before authorizing cleanup.
sub run_probe {
    my ($stdout,@args)=@_;my $name='visllama-probe-'.$$.'-'.substr(sha256_hex(time().rand()),0,12);
    my $result=eval {command($stdout,'run','--rm','--name',$name,'--label','visllama.owner='.$OWNER,@args)};
    return $result unless $@;
    my $error=$@;my $raw=eval {command(1,'inspect',$name)};my $inspection_error=$@;
    if ($inspection_error && $inspection_error =~ /No such (?:object|container)/i) {die $error;}
    my $proc=bless {name=>$name,owner=>$OWNER},'VisLlama::Docker::Process';
    if (!$inspection_error) {my $info=decode($raw)->[0];$proc->{id}=$info->{Id} if $info && ($info->{Config}{Labels}{'visllama.owner'}//'') eq $OWNER;}
    $PENDING{$name}=$proc;
    eval {$proc->stop()};delete $PENDING{$name} if $proc->{removed};
    die $error.($proc->{removed}?'':"\nDocker probe cleanup is unconfirmed; retry Stop.");
}
sub resolve {
    my ($ref,$refresh)=@_;my $tag=image($ref);validate_image($tag);
    return $INFO{$tag}{info} if !$refresh && $INFO{$tag} && time()-$INFO{$tag}{at}<10;
    # Host networking and same-path mounts require a local Linux Docker daemon.
    die 'Docker requires a local Unix-socket daemon for host model mounts' if length($ENV{DOCKER_HOST}//'') && $ENV{DOCKER_HOST} !~ m{\Aunix://};
    my $context=decode(command(1,'context','inspect'))->[0];
    die 'Docker requires a local Unix-socket daemon for host model mounts' unless ($context->{Endpoints}{docker}{Host}//'') =~ m{\Aunix://};
    die 'Docker requires Linux containers' unless command(1,'info','--format','{{.OSType}}') =~ /\Alinux\s*\z/;
    my $raw=eval {command(1,'image','inspect',$tag)};
    if ($@) {
        # Pulling is explicit in operational logs; it is bounded and cancellable.
        warn 'VisLlama: Pulling Docker image '.$tag."\n";
        {local $VisLlama::Command::TIMEOUT=600;my $out=VisLlama::Command::capture(0,$CLI,'pull',$tag);die 'Docker image pull failed: '.$out if $?;}
        $raw=command(1,'image','inspect',$tag);
    }
    my $info=decode($raw)->[0];die 'Docker image has no resolved ID' unless ($info->{Id}//'') =~ /\Asha256:[a-f0-9]{64}\z/;
    my $entry=$info->{Config}{Entrypoint}||[];my $cmd=$info->{Config}{Cmd}||[];
    die 'Invalid Docker image startup metadata' unless ref($entry) eq 'ARRAY' && ref($cmd) eq 'ARRAY';
    # Direct server entrypoints accept flags alone. NVIDIA/general wrappers need
    # an explicit command; preserve their initialization instead of bypassing it.
    my $direct=@$entry && basename($entry->[-1]) eq 'llama-server';
    my $server=$direct ? $entry->[-1] : (@$cmd && basename($cmd->[0]) eq 'llama-server' ? $cmd->[0] : 'llama-server');
    $info->{server}=$server;$info->{server_command}=$direct?[]:[$server];
    $INFO{$tag}={at=>time(),info=>$info};return $info;
}
sub gpu_args {return -e '/dev/nvidiactl' ? ('--gpus','all') : ()}
sub probe {
    my ($ref,$flag)=@_;die 'Invalid Docker build probe' unless $flag =~ /\A--(?:help|version|list-devices)\z/;
    my $info=resolve($ref);my $key=$info->{Id}.'|'.$flag;
    if ($flag ne '--list-devices' && exists $PROBES{$key}) {$?=0;return $PROBES{$key};}
    my $text=run_probe(0,gpu_args(),$info->{Id},@{$info->{server_command}},$flag);
    %PROBES=() if keys(%PROBES)>64;
    $PROBES{$key}=$text if $flag ne '--list-devices';$?=0;return $text;
}
sub csv_mount {
    my ($source,$target,$readonly)=@_;my @parts=('type=bind','source='.$source,'target='.$target);
    push @parts,'readonly' if $readonly;
    for (@parts) {if (/[,"]/) {s/"/""/g;$_='"'.$_.'"';}}
    return join(',',@parts);
}
sub mount_paths {
    my ($ref,@args)=@_;my %paths;
    my $add=sub {my ($path,$rw)=@_;return unless defined($path) && length($path);die 'Docker mount source is missing: '.$path unless -d $path;
        my $absolute=File::Spec->rel2abs($path);$paths{$absolute}=$rw?1:($paths{$absolute}||0);
        my $real=abs_path($path);$paths{$real}=$rw?1:($paths{$real}||0) if defined $real;};
    $add->($CFG{model_root},0) if length($CFG{model_root}//'');
    my $logs=File::Spec->catdir(VisLlama::Paths::app_base_dir(),'logs');mkdir $logs unless -d $logs;
    $add->(VisLlama::Paths::presets_dir(),0);$add->($logs,1);
    # Include referenced external files without requiring container-path fields.
    require VisLlama::Catalog;
    for my $p (@{VisLlama::Catalog::load_router_presets()}) {
        next unless ($CFG{builds}{$p->{build}//''}//'') eq $ref;
        $add->(dirname($p->{model}),0) if -f ($p->{model}//'');
        for my $o (@{$p->{options}||[]}) {
            $add->(dirname($o->[1]),0) if $o->[0] =~ /\A(?:chat-template-file|spec-draft-model|model-draft|mmproj|lora)\z/ && -f ($o->[1]//'');
        }
    }
    for (my $i=0;$i<@args-1;$i++) {
        $add->(dirname($args[$i+1]),0) if $args[$i] =~ /\A(?:-m|--model|--chat-template-file|--spec-draft-model|--model-draft|--mmproj|--lora)\z/ && -f $args[$i+1];
    }
    return \%paths;
}
sub identity {
    my ($ref)=@_;my $info=resolve($ref);
    die 'Container GGML_CUDA_DEVICES remapping is unsupported' if grep {/\AGGML_CUDA_DEVICES=.+/} @{$info->{Config}{Env}||[]};
    # Trace the server in the image, not similarly named host CUDA libraries.
    my $trace=run_probe(0,gpu_args(),'--env','LD_DEBUG=libs',$info->{Id},@{$info->{server_command}},'--list-devices');
    my (%backend,%runtime);
    for my $line (split /\n/,$trace) {
        next unless $line =~ /calling init:\s+(\/[^\r\n]+?)\s*$/;
        my $path=$1;$backend{$path}=1 if $path =~ m{/libggml-cuda\.so(?:\.[0-9.]+)?$};
        $runtime{$path}=1 if $path =~ m{/libcudart\.so(?:\.[0-9.]+)?$};
    }
    die 'Docker CUDA linkage cannot be verified' unless (keys(%backend)==1 || (!keys(%backend) && keys(%runtime)==1)) && keys(%runtime)<=1;
    my $backend=keys(%backend)?(keys %backend)[0]:(keys %runtime)[0];
    my $runtime=keys(%runtime)?(keys %runtime)[0]:$backend;
    require VisLlama::Platform::CUDA;
    my $helper=VisLlama::Platform::CUDA::helper();
    # Host and image must have compatible Linux ABI for this small native helper;
    # failure is explicit, never a substitution of SMI indices for CUDA ordinals.
    my $json=run_probe(1,gpu_args(),'--mount',csv_mount($helper,'/visllama-cuda-helper',1),
        '--entrypoint','/visllama-cuda-helper',$info->{Id},$backend,$runtime);
    $?=0;return $json;
}
sub inspect_owned {
    my ($self)=@_;my $info=decode(command(1,'inspect',$self->{id}||$self->{name}))->[0];
    die 'Docker container ownership no longer matches' unless ($info->{Id}//'') =~ /\A[a-f0-9]{64}\z/ && (!$self->{id} || $info->{Id} eq $self->{id}) && ($info->{Config}{Labels}{'visllama.owner'}//'') eq $self->{owner};
    $self->{id}=$info->{Id};
    return $info;
}
sub launch {
    my ($spec)=@_;my $info=resolve($spec->{exe},1);
    die 'Docker image changed after GPU verification; restart the action' if $spec->{docker_image_id} && $spec->{docker_image_id} ne $info->{Id};
    if (grep {$_ eq '--models-preset'} @{$spec->{args}}) {
        die 'The Docker image does not advertise llama.cpp Router support. Choose an image with --models-preset support.'
            unless probe($spec->{exe},'--help') =~ /--models-preset\b/;
    }
    my $paths=mount_paths($spec->{exe},@{$spec->{args}});my $name='visllama-'.$$.'-'.substr(sha256_hex(time().rand()),0,12);
    my @args=('create','--name',$name,'--label','visllama.owner='.$OWNER,'--network','host',gpu_args());
    push @args,('--mount',csv_mount($_,$_,$paths->{$_}?0:1)) for sort keys %$paths;
    push @args,('--env',$_.'='.$spec->{env}{$_}) for sort keys %{$spec->{env}||{}};
    push @args,$info->{Id},@{$info->{server_command}},@{$spec->{args}};
    my $id=command(1,@args);$id =~ s/\s+\z//;die 'Docker returned an invalid container ID' unless $id =~ /\A[a-f0-9]{64}\z/;
    my $proc=bless {id=>$id,owner=>$OWNER,image_id=>$info->{Id},ref=>$spec->{exe},log=>$spec->{log},exit_file=>$spec->{exit_file},mounts=>$paths},'VisLlama::Docker::Process';
    $PENDING{$id}=$proc;
    eval {
        command(1,'start',$id);my $state=inspect_owned($proc)->{State};$proc->{pid}=$state->{Pid}||$$;
        require VisLlama::Platform::Linux;
        $proc->{logger}=VisLlama::Platform::Linux->launch({exe=>$CLI,args=>['logs','--follow',$id],cwd=>VisLlama::Paths::app_base_dir(),log=>$spec->{log},env=>{}});
        open my $log,'>>:raw',$spec->{log} or die 'Cannot write Docker launch log';
        print {$log} 'VisLlama Docker image '.$info->{Id}.'; container '.$id."\n";close $log;
        delete $PENDING{$id};1;
    } or do {my $error=$@;eval {$proc->stop()};delete $PENDING{$id} if $proc->{removed};die $error;};
    return $proc;
}
sub pending_running {return scalar keys %PENDING}
sub stop_pending {my $ok=1;for my $id (keys %PENDING) {if (eval {$PENDING{$id}->stop()}) {delete $PENDING{$id}} else {$ok=0}}return $ok}
sub check_live {
    my ($proc,$ref,$files)=@_;return unless $proc && $proc->isa('VisLlama::Docker::Process');
    die 'Restart Router to apply the new build or GPU visibility groups.' if $proc->{ref} ne $ref || resolve($ref)->{Id} ne $proc->{image_id};
    for my $file (@$files) {
        die 'Restart Router to apply the new build or GPU visibility groups.' unless grep {VisLlama::Paths::canonical_under($file,$_)} keys %{$proc->{mounts}};
    }
}
END {eval {stop_pending()}}

package VisLlama::Docker::Process;
use strict;
use warnings;
sub GetProcessID {$_[0]{pid}||$$}
sub finish {
    my ($self,$exit)=@_;
    die 'Docker log follower stop is unconfirmed' if $self->{logger} && !$self->{logger}->stop();
    delete $self->{logger};
    if (!$self->{rm_requested}) {VisLlama::Docker::command(1,'rm',$self->{id});$self->{rm_requested}=1;$self->{exit}=$exit;}
    die 'Docker removal unconfirmed' if VisLlama::Docker::command(1,'ps','-aq','--filter','id='.$self->{id}) =~ /\S/;
    $self->{removed}=1;$self->{exit}=$exit;
    if ($self->{exit_file}) {open my $fh,'>:raw',$self->{exit_file} or die 'Cannot write Docker exit status';print {$fh} $exit;close $fh;}
    return 1;
}
sub GetExitCode {
    my ($self)=@_;
    if ($self->{removed}) {$_[1]=$self->{exit};return 1;}
    if ($self->{rm_requested}) {$self->finish($self->{exit});$_[1]=$self->{exit};return 1;}
    my $info=VisLlama::Docker::inspect_owned($self);
    if ($info->{State}{Running}) {$_[1]=259;return 1;}
    $self->finish($info->{State}{ExitCode}//0);$_[1]=$self->{exit};return 1;
}
sub stop {
    my ($self)=@_;return 1 if $self->{removed};
    return $self->finish($self->{exit}) if $self->{rm_requested};
    my $info=VisLlama::Docker::inspect_owned($self);
    VisLlama::Docker::command(1,'stop','--time','15',$self->{id}) if $info->{State}{Running};
    $info=VisLlama::Docker::inspect_owned($self);die 'Docker stop is unconfirmed' if $info->{State}{Running};
    return $self->finish($info->{State}{ExitCode}//0);
}
sub Kill {$_[0]->stop()}
1;
