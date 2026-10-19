package VisLlama::Preflight;
# GPL-3.0-only. Static validation before any destructive reload step. This does
# not sample VRAM or promise a fit; Calculated still plans after required unload.
use strict;
use VisLlama::Engines ();
use warnings;
use File::Basename qw(basename dirname);
use File::Spec ();
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Time::HiRes qw(time);
use VisLlama::Context qw(%CFG $STATE);
use VisLlama::Builds ();
use VisLlama::Paths ();
use VisLlama::Arguments ();
use VisLlama::GPUIsolation ();
use VisLlama::Lifecycle ();
use VisLlama::Storage ();
my %TICKETS;
sub signature {
    my ($req)=@_;
    return sha256_hex(JSON::PP->new->ascii->canonical->encode({map {$_=>$req->{$_}} qw(alias original_alias build model args ui)}));
}
sub validate {
    my ($req,$live,$recheck)=@_;
    my $build=$req->{build}//'';my $model=$req->{model}//'';
    die 'Unknown build' unless exists $CFG{builds}{$build};
    my $exe=VisLlama::Builds::find_server_exe($CFG{builds}{$build});
    die 'llama-server executable not found' unless $exe && (-f $exe || $exe =~ m{\Adocker://});
    die 'Model file is missing or outside the configured GGUF root'
        unless $model =~ /\.gguf$/i && -f $model && VisLlama::Paths::canonical_under($model,$CFG{model_root});
    my $args=VisLlama::Arguments::normalize($req->{args}||[]);
    require VisLlama::Catalog;
    my $options=VisLlama::Catalog::args_to_preset_options($args);
    my @files=($model);push @files,$exe unless $exe =~ m{\Adocker://};
    # Validate every split shard before disrupting the current model. This is
    # file presence only; GGUF metadata/fit remain the loader's responsibility.
    if (basename($model) =~ /^(.*)-(\d{5})-of-(\d{5})\.gguf$/i) {
        my ($prefix,$count)=($1,0+$3);
        die 'Invalid GGUF shard count' unless $count>=1 && $count<=9999;
        for my $n (1..$count) {
            my $shard=File::Spec->catfile(dirname($model),sprintf('%s-%05d-of-%05d.gguf',$prefix,$n,$count));
            die 'A split GGUF shard is missing' unless -f $shard;
            push @files,$shard;
        }
    }
    for my $option (@$options) {
        next unless $option->[0] =~ /^(?:chat-template-file|spec-draft-model|model-draft|mmproj|lora)$/;
        die 'A referenced model, adapter or chat template file is missing' unless length($option->[1]) && -f $option->[1];
        push @files,$option->[1];
    }
    my $preset={alias=>$req->{alias},build=>$build,model=>$model,options=>$options,ui=>$req->{ui}||{}};
    my $key=VisLlama::GPUIsolation::group_key($preset);
    my $eng=$STATE->{router_engines}{$key};
    if ($live) {
        die 'Restart Router to apply the new build or GPU visibility groups.' unless $eng;
        require VisLlama::ProcessState;
        die 'Target Router engine is no longer running' unless VisLlama::ProcessState::router_engine_running($eng);
        VisLlama::Docker::check_live($eng->{proc},$exe,\@files) if VisLlama::Docker::is_ref($exe);
        # Mapping validation uses the already verified physical profile. It must
        # not silently reinterpret original CUDA IDs as local ordinals.
        VisLlama::GPUIsolation::remap_options($options,$eng->{isolation}) if $eng->{isolation};
    }
    # Help text is guidance, not an exhaustive schema for every llama.cpp build.
    # Native loading reports unsupported flags; do not reject preserved custom
    # options or run repeated capability probes during ordinary save/load.
    if (!$recheck && ($req->{ui}{gpuPriority}//$req->{gpu_priority}//'') eq 'priority_split') {
        require VisLlama::PlannerSettings;
        my $help=VisLlama::Builds::checked_probe($exe,'--help');
        my $settings=VisLlama::PlannerSettings::from_args($req->{ui},$args,$help,undef);
        die $settings->{_unsupported} if $settings->{_unsupported};
    }
    return sha256_hex($exe.join('\n',map {my @s=stat($_);$_.'|'.($s[7]//0).'|'.($s[9]//0)} @files));
}
sub catalog_signature {require VisLlama::Catalog;my ($path)=VisLlama::Catalog::router_paths();return sha256_hex(VisLlama::Storage::read($path)//'')}
sub issue {
    my ($req)=@_;my $live=$req->{live}?1:0;
    if ($live) {
        require VisLlama::Catalog;
        my $preset={build=>$req->{build},ui=>$req->{ui}||{},options=>VisLlama::Catalog::args_to_preset_options(VisLlama::Arguments::normalize($req->{args}||[]))};
        unless ($STATE->{router_engines}{VisLlama::GPUIsolation::group_key($preset)}) {
            # A new visibility group cannot replace a child in an existing
            # engine. Save normally and tell the caller to restart explicitly.
            validate($req,0);return undef;
        }
    }
    my $files=validate($req,$live);
    delete $TICKETS{$_} for grep {$TICKETS{$_}{expires}<time()} keys %TICKETS;
    die 'Too many pending preflight requests' if keys(%TICKETS)>=128;
    my $id=sha256_hex(join(':',time(),rand(),$$,signature($req)));
    $TICKETS{$id}={request=>$req,catalog=>catalog_signature(),files=>$files,signature=>signature($req),runtime=>VisLlama::Lifecycle::token(),expires=>time()+180,live=>$live};
    return $id;
}
sub check {
    my ($req,$save)=@_;
    my $ticket=$TICKETS{$req->{preflight_id}//''} or die 'Preflight expired. Validate the model again.';
    die 'Model settings changed after preflight. Validate again.' if catalog_signature() ne $ticket->{catalog};
    die 'Preflight expired. Validate the model again.' if $ticket->{expires}<time();
    die 'Runtime changed. Refresh status and retry the action.' unless $ticket->{runtime} eq VisLlama::Lifecycle::token();
    die 'Model settings changed after preflight. Validate again.' if $save && signature($req) ne $ticket->{signature};
    my $original=$ticket->{request}{original_alias}||$ticket->{request}{alias}||'';
    die 'Preflight model does not match the requested unload' if !$save && ($req->{model}//'') ne $original;
    die 'Model files changed after preflight. Validate again.' unless validate($ticket->{request},$ticket->{live},1) eq $ticket->{files};
    return 1;
}
# An ordinary reload saves before unloading. Advance only its validated ticket
# after the successful catalog commit; unrelated edits still invalidate it.
sub committed {
    my ($req)=@_;
    return unless $req->{preflight_id};
    my $ticket=$TICKETS{$req->{preflight_id}} or die 'Preflight expired';
    $ticket->{catalog}=catalog_signature();
}
sub saved {
    my ($preset,$live)=@_;
    return VisLlama::Engines::validate_preset($preset,1) if VisLlama::Engines::external($preset);
    require VisLlama::PlannerSettings;
    return validate({%$preset,args=>VisLlama::PlannerSettings::option_args($preset->{options})},$live);
}
1;
