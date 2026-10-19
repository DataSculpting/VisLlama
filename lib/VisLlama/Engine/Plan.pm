package VisLlama::Engine::Plan;
# GPL-3.0-only. Pure typed rendering; preview never writes artifacts or runs probes.
use strict;
use warnings;
use JSON::PP ();
use Storable qw(dclone);
use File::Spec;
use VisLlama::Engine::Registry ();
sub expand {
    my ($value,$vars)=@_;
    return {map {$_=>expand($value->{$_},$vars)} keys %$value} if ref($value) eq 'HASH';
    return [map {expand($_,$vars)} @$value] if ref($value) eq 'ARRAY';
    return $value if ref($value) || !defined($value);
    if ($value =~ /\A\$\{([a-z_]+)\}\z/) {die 'Unknown engine placeholder' unless exists $vars->{$1};return $vars->{$1};}
    $value =~ s/\$\{([a-z_]+)\}/exists($vars->{$1})?$vars->{$1}:die('Unknown engine placeholder')/ge;
    die 'Invalid engine placeholder' if $value =~ /\$\{/;return $value;
}
sub set_path {
    my ($target,$path,$value)=@_;my $node=$target;
    for my $i (0..$#$path-1) {my $k=$path->[$i];$node->{$k}={} unless exists $node->{$k};die 'Config field conflicts with a non-object' unless ref($node->{$k}) eq 'HASH';$node=$node->{$k};}
    $node->{$path->[-1]}=$value;
}
sub get_path {my ($node,$path)=@_;for my $k (@$path) {return undef unless ref($node) eq 'HASH';$node=$node->{$k};}return $node;}
sub apply_config_flag {
 my ($config,$f,$value)=@_;my $args=get_path($config,$f->{path});$args=[] unless defined($args);die 'Config argument target must be an array' unless ref($args) eq 'ARRAY';
 my @new;for(my $i=0;$i<@$args;$i++){my $arg=$args->[$i];if($arg eq $f->{flag}) {$i++ if $f->{type} ne 'boolean';next;}next if index($arg,$f->{flag}.'=')==0;push @new,$arg;}
 if($f->{type} eq 'boolean'){push @new,$f->{flag} if $value;}elsif (defined $value) {push @new,$f->{flag},"$value";}
 set_path($config,$f->{path},\@new);
}
sub delete_path {my ($node,$path)=@_;for my $key (@$path[0..$#$path-1]) {return unless ref($node->{$key}) eq 'HASH';$node=$node->{$key};}delete $node->{$path->[-1]};}
sub flag_present {my ($args,$flag)=@_;return ref($args) eq 'ARRAY' && grep {$_ eq $flag || index($_,$flag.'=')==0} @$args;}
sub field_value {
    my ($f,$v)=@_;
    if ($f->{type} eq 'json-array') {die 'Expected argument array' unless ref($v) eq 'ARRAY' && !grep {!VisLlama::Engine::Registry::scalar_text($_)} @$v;return dclone($v);}
    if ($f->{type} eq 'boolean') {die 'Expected boolean setting' unless JSON::PP::is_bool($v);return $v;}
    die 'Expected scalar setting' unless VisLlama::Engine::Registry::scalar_text($v);
    if ($f->{format}) {my $auto=$f->{format} eq 'auto-or-integer-csv' && $v eq 'auto';die 'Use comma-separated whole numbers, or auto where supported.' unless $auto || $v =~ /\A\d+(?:\s*,\s*\d+)*\z/;}
    if ($f->{type} =~ /integer|number/) {
        die 'Invalid numeric setting' unless $v =~ ($f->{type} eq 'integer'?qr/\A-?\d+\z/:qr/\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/) && abs($v)<1e15;
        die 'Setting below minimum' if defined($f->{minimum}) && $v<$f->{minimum};
        die 'Setting above maximum' if defined($f->{maximum}) && $v>$f->{maximum};$v=0+$v;
    }
    die 'Unsupported enum choice' if $f->{enum} && !grep {"$_" eq "$v"} @{$f->{enum}};
    return $v;
}
sub render {
    my ($d,$b,$p,$instance,$port)=@_;
    $p={%$p,settings=>{%{$p->{settings}||{}}}};for my $field (@{$d->{fields}}) {next if exists($p->{settings}{$field->{key}});for my $key (@{$field->{legacy_keys}||[]}) {if(exists($p->{settings}{$key})){$p->{settings}{$field->{key}}=$p->{settings}{$key};last;}}}
    die 'Invalid engine settings' unless ref($p->{settings}) eq 'HASH';
    my $config=dclone($p->{native_config}||{});die 'Native config must be an object' unless ref($config) eq 'HASH';
    my %vars=(runtime_library_dirs=>$b->{runtime_library_dirs}||[],runtime_executable=>$b->{runtime_executable}//'',executable=>$b->{executable},root=>$b->{root},model=>$p->{model},alias=>$p->{alias},port=>0+$port,host=>'127.0.0.1',instance=>$instance,runtime_config=>"$instance/config.json",log=>"$instance/engine.log",native_log=>"$instance/native.log");
    my $creating=($p->{config_mode}//'import') eq 'create';
    if ($creating) {my $defaults=expand($d->{new_config}||{},\%vars);$config={%$defaults,%$config};}
    my @argv=@{expand($d->{argv},\%vars)};my %env;
    my %known=map {($_->{key}=>1,map {$_=>1} @{$_->{legacy_keys}||[]})} @{$d->{fields}};
    my %by_key=map {$_->{key}=>$_} @{$d->{fields}};
    my @inactive=grep {!$known{$_}} keys %{$p->{settings}};
    for my $f ((grep {$_->{binding} ne 'config-flag'} @{$d->{fields}}),(grep {$_->{binding} eq 'config-flag'} @{$d->{fields}})) {
        next unless exists $p->{settings}{$f->{key}};
        if (!defined($p->{settings}{$f->{key}}) && $f->{binding}=~/\Aconfig(?:-flag)?\z/) {
            for my $flag (@{$f->{clear_flags}||[]}) {apply_config_flag($config,{path=>$flag->{path}||['args'],flag=>$flag->{flag},type=>$flag->{takes_value}?'string':'boolean'},undef);}
            if($f->{binding} eq 'config-flag'){apply_config_flag($config,$f,undef)}else{delete_path($config,$f->{path})}next;
        }
        if (exists($f->{available}) && !$f->{available}) {push @inactive,$f->{key};next;}
        if ($f->{when}) {my $rule=$f->{when};my $dep=$by_key{$rule->{key}};my $value=exists($p->{settings}{$rule->{key}})?$p->{settings}{$rule->{key}}:($dep->{binding} eq 'config'?get_path($config,$dep->{path}):undef);next unless defined($value) && "$value" eq "$rule->{equals}";}
        my $v=field_value($f,$p->{settings}{$f->{key}});
        if ($f->{type} ne 'boolean' || $v || $f->{binding} eq 'config') {for my $flag (@{$f->{clear_flags}||[]}) {apply_config_flag($config,{binding=>'config-flag',path=>$flag->{path}||['args'],flag=>$flag->{flag},type=>$flag->{takes_value}?'string':'boolean'},undef);}}
        if ($f->{binding} eq 'none') {next;}
        elsif ($f->{binding} eq 'config-flag') {apply_config_flag($config,$f,$v);}
        elsif ($f->{binding} eq 'config') {set_path($config,$f->{path},$v);}
        elsif ($f->{binding} eq 'environment') {$env{$f->{name}}="$v";}
        elsif ($f->{type} eq 'boolean') {push @argv,$f->{flag} if $v;}
        else {push @argv,$f->{flag},"$v";}
    }
    if ($creating) {
        for my $f (@{$d->{fields}}) {
            next unless $f->{required};next if exists($f->{available}) && !$f->{available};
            next if $f->{when} && ($p->{settings}{$f->{when}{key}}//'') ne $f->{when}{equals};
            my $v=exists($p->{settings}{$f->{key}})?$p->{settings}{$f->{key}}:($f->{binding} eq 'config'?get_path($config,$f->{path}):undef);
            die 'Engine configuration is incomplete. Fill required fields and check required files.' unless defined($v) && (ref($v)||length($v));
        }
        for my $m (grep {!$_->{preserve_existing}} @{$d->{model_bindings}||[]}) {apply_config_flag($config,{%$m,type=>'string'},undef);}
        for my $m (@{$d->{model_bindings}||[]}) {next unless ($p->{settings}{$m->{key}}//'') eq $m->{equals};next if $m->{preserve_existing} && (flag_present(get_path($config,$m->{path}),$m->{flag}) || grep {$_->{binding} eq 'config-flag' && $_->{flag} eq $m->{flag} && join('/',@{$_->{path}}) eq join('/',@{$m->{path}}) && exists($p->{settings}{$_->{key}}) && !defined($p->{settings}{$_->{key}})} @{$d->{fields}});if($m->{kind}) {die 'Prepared model path does not match the selected model format.' unless $m->{kind} eq 'file'?-f $p->{model}:-d $p->{model};}apply_config_flag($config,{%$m,type=>'string'},$p->{model});}
        for my $q (@{$d->{requirements}||[]}) {
            my $v=get_path($config,$q->{path});my $ok;
            if ($q->{kind} eq 'array') {$ok=ref($v) eq 'ARRAY' && @$v;}
            elsif (defined($v) && !ref($v) && length($v)) {my $base=$config->{cwd}||$b->{root};$base=File::Spec->rel2abs($base,$b->{root});my $path=File::Spec->rel2abs($v,$base);$ok=$q->{kind} eq 'file'?-f $path:-d $path;$ok=0 if $ok && grep {!-f File::Spec->catfile($path,$_)} @{$q->{children}||[]};}
            die 'Engine configuration is incomplete. Fill required fields and check required files.' unless $ok;
        }
    }
    my $fixed=expand($d->{config_overrides}||{},\%vars);$config->{$_}=$fixed->{$_} for keys %$fixed;
    die 'Native argv contains an invalid value' if grep {!VisLlama::Engine::Registry::scalar_text($_)} @argv;
    return {engine=>$d->{id},definition_digest=>$d->{digest},build_id=>$b->{id},preset=>$p->{alias},exe=>shift(@argv),args=>\@argv,cwd=>$b->{root},env=>\%env,config=>$config,config_path=>$vars{runtime_config},log=>$vars{log},inactive_fields=>\@inactive,additive_digest=>$d->{additive_digest}//'',readiness=>$d->{readiness},port=>0+$port};
}
1;
