package VisLlama::PlannerSettings;

# Resolve the settings actually sent to llama.cpp. A UI snapshot is an editor
# convenience, not authoritative when raw/build-specific options override it.
use strict;
use warnings;
use VisLlama::Builds ();

my %VALUE=(
    'ctx-size'=>'ctx','parallel'=>'parallel','batch-size'=>'batch','ubatch-size'=>'ubatch',
    'cache-type-k'=>'cacheK','cache-type-v'=>'cacheV','spec-type'=>'specType',
    'spec-draft-n-max'=>'draftTokens','kv-unified-per-slot'=>'kvUnifiedPerSlot',
    'spec-draft-type-k'=>'draftTypeK','spec-draft-type-v'=>'draftTypeV',
    'spec-draft-device'=>'draftDevice','spec-draft-ngl'=>'draftNgl','model-draft'=>'draft','spec-draft-model'=>'draft',
    'n-cpu-moe'=>'nCpuMoe','flash-attn'=>'flashMode',
);
my %BOOL=('swa-full'=>'swaFull','no-kv-offload'=>'noKvOffload','cpu-moe'=>'cpuMoe');

sub from_args {
    my ($ui,$args,$help,$build_number)=@_;
    my %s=%{ref($ui) eq 'HASH' ? $ui : {}};
    delete @s{qw(_unsupported _build_number _swa_profile _default_note)};
    if (ref($args) eq 'ARRAY') {
        # With a real launch list, omitted flags mean engine defaults, not stale UI.
        delete @s{values %VALUE,values %BOOL,'kvUnified','flash'};
        my %alias=(c=>'ctx-size',np=>'parallel',b=>'batch-size',ub=>'ubatch-size',
            ctk=>'cache-type-k',ctv=>'cache-type-v',fa=>'flash-attn',nkvo=>'no-kv-offload',
            cmoe=>'cpu-moe',ncmoe=>'n-cpu-moe',md=>'model-draft');
        for (my $i=0;$i<@$args;$i++) {
            my $token=$args->[$i];next unless defined($token) && !ref($token) && $token =~ /^--?([\w.-]+)(?:=(.*))?$/s;
            my ($flag,$inline)=($1,$2);$flag=$alias{$flag}//$flag;
            my $value=$inline;
            if (!defined($value) && $i+1<@$args && defined($args->[$i+1]) && !ref($args->[$i+1]) && $args->[$i+1] !~ /^--?[A-Za-z]/) {
                $value=$args->[++$i];
            }
            if (my $field=$VALUE{$flag}) { $s{$field}=defined($value)?$value:''; }
            elsif (my $boolean_field=$BOOL{$flag}) { $s{$boolean_field}=!defined($value)||$value !~ /^(?:false|off|0)$/i ? 1:0; }
            elsif ($flag eq 'kv-unified' || $flag eq 'no-kv-unified') {
                my $enabled=!defined($value)||$value !~ /^(?:false|off|0)$/i;
                $enabled=!$enabled if $flag eq 'no-kv-unified';
                $s{kvUnified}=$enabled?'on':'off';
            }
            elsif ($flag =~ /^(?:override-kv|override-tensor|ot|lora|lora-scaled|mmproj|mmproj-offload|no-mmproj-offload|tensor-buft-overrides|spec-draft-cpu-moe|spec-draft-n-cpu-moe|embedding|embeddings|pooling)$/) {
                $s{_unsupported}='Custom tensor/metadata overrides, adapters, multimodal or embedding options need engine-native fitting or a manual split.';
            }
        }
    }
    $s{flash}=(($s{flashMode}//'') eq 'on' || $s{flash}) ? 1:0;
    $s{_build_number}=$build_number if defined $build_number;
    $s{_swa_profile}=defined($build_number) && ($build_number==10819 || $build_number==11223) ? 1:0;
    my %defaults;
    for my $option (@{VisLlama::Builds::parse_help($help//'')}) {
        my ($value)=($option->{description}//'')=~/\bdefault:\s*([A-Za-z0-9_.-]+)\b/i;
        next unless defined $value;
        for my $flag (@{$option->{aliases}||[]}) {
            $flag=~s/^--//;
            next unless exists $VALUE{$flag};
            my $field=$VALUE{$flag};
            $defaults{$field}=$value if $value=~/^-?\d+$/ || $field=~/^(?:cache[KV]|draftType[KV])$/;
        }
    }
    # --parallel auto in the inspected server builds resolves to four slots and
    # unified KV, overriding a no-kv-unified flag. Never infer slots from an alias.
    if (!defined($s{parallel}) || $s{parallel} eq '' || $s{parallel} eq '-1') {
        my $auto=defined($s{parallel}) && $s{parallel} eq '-1';
        my $default=$auto ? -1 : ($defaults{parallel}//-1);
        $s{parallel}=$default>0 ? $default:4;
        $s{kvUnified}='on' if $default<0;
        $s{_default_note}='Automatic slot count is estimated as four; explicitly set Parallel slots when using other build defaults.' if $default<0 && !$s{_swa_profile};
    }
    $s{kvUnified}='off' unless ($s{kvUnified}//'') =~ /^(?:on|off)$/;
    $s{batch}=$defaults{batch}//2048 unless defined($s{batch}) && $s{batch} ne '';
    $s{ubatch}=$defaults{ubatch}//512 unless defined($s{ubatch}) && $s{ubatch} ne '';
    $s{ctx}=$defaults{ctx} if (!defined($s{ctx}) || $s{ctx} eq '') && ($defaults{ctx}//0)>0;
    for my $field (qw(cacheK cacheV draftTypeK draftTypeV)) {
        $s{$field}=$defaults{$field}//'f16' unless defined($s{$field}) && length($s{$field});
    }
    # Draft model residency cannot be inferred from the target model's GGUF.
    if (length($s{draft}//'') || ($s{specType}//'') =~ /(?:draft-simple|draft-eagle|draft-dflash|draft-dspark)/) {
        $s{_unsupported}='A separate draft model needs engine-native fitting or a manual split; its memory is not included in the target GGUF.';
    }
    if (length($s{draftDevice}//'') || length($s{draftNgl}//'')) {
        $s{_unsupported}='Separate draft device/offload placement needs engine-native fitting or a manual split.';
    }
    return \%s;
}

# Catalog options already have effective flag/value boundaries; preserve order
# and repeated options when feeding the same resolver used by the editor preview.
sub option_args {
    my ($options)=@_;
    return [map { ('--'.$_->[0],$_->[1]) } grep {ref($_) eq 'ARRAY' && @$_==2} @{$options||[]}];
}

1;
