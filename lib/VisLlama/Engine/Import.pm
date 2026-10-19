package VisLlama::Engine::Import;
# GPL-3.0-only. Read-only configuration inspection; no file writes or engine probes.
use strict;use warnings;use File::Spec;use File::Spec::Win32;use File::Spec::Unix;
use VisLlama::Engine::Registry ();use VisLlama::Engine::Plan ();
sub path_value {VisLlama::Engine::Plan::get_path($_[0],$_[1])}
sub rule_values {
 my ($config,$rule)=@_;my $value=path_value($config,$rule->{path});
 return (defined($value)&&!ref($value)?($value):()) unless $rule->{flag};
 return () unless ref($value) eq 'ARRAY';my @values;
 for(my $i=0;$i<@$value;$i++){my $token=$value->[$i];next if ref($token)||!defined($token);if($token eq $rule->{flag}){push @values,$value->[++$i] if $i+1<@$value;}elsif(index($token,$rule->{flag}.'=')==0){push @values,substr($token,length($rule->{flag})+1);}}
 return @values;
}
sub resolve_path {
 my ($value,$base,$root,$windows)=@_;my $spec=$windows?'File::Spec::Win32':'File::Spec::Unix';
 return $value if $spec->file_name_is_absolute($value);
 # Drive-relative Windows paths depend on hidden per-drive working directories.
 return undef if $windows && $value=~/\A[A-Za-z]:/;
 $base=$root unless defined($base)&&!ref($base)&&length($base);
 return undef unless defined($base)&&length($base)&&defined($root)&&length($root);
 $base=$spec->rel2abs($base,$root) unless $spec->file_name_is_absolute($base);
 return $spec->canonpath($spec->rel2abs($value,$base));
}
sub inspect {
 my ($d,$b,$config)=@_;die 'Native JSON must be an object' unless ref($config) eq 'HASH';
 my $ui=($d->{ui}||{})->{import}||{};my @warnings;
 my $alias;
 if($ui->{alias_path}){$alias=path_value($config,$ui->{alias_path});}
 else {my @keys=sort grep {defined($d->{config_overrides}{$_})&&!ref($d->{config_overrides}{$_})&&$d->{config_overrides}{$_} eq '${alias}'} keys %{$d->{config_overrides}||{}};$alias=$config->{$keys[0]} if @keys==1;}
 $alias='' unless VisLlama::Engine::Registry::scalar_text($alias);
 my @rules=@{$ui->{model_paths}||[map {{path=>$_->{path},flag=>$_->{flag}}} @{$d->{model_bindings}||[]}]};
 my $model='';my $ambiguous=0;
 for my $rule (@rules){my %seen;my @v=grep {VisLlama::Engine::Registry::scalar_text($_)&&length($_)&&!$seen{$_}++} rule_values($config,$rule);next unless @v;if(@v>1){$ambiguous=1;last;}$model=$v[0];last;}
 if($ambiguous){push @warnings,'Multiple model paths match the preferred configuration option. Choose the catalog model path below.';}
 elsif(!length($model)){push @warnings,'The catalog model path could not be identified from this definition. Choose it below.';}
 if(length($model)){
  my $base=$ui->{base_path}?path_value($config,$ui->{base_path}):(exists(($d->{new_config}||{})->{cwd})?$config->{cwd}:undef);
  my $foreign=$^O ne 'MSWin32' && $model=~/\A(?:[A-Za-z]:[\\\/]|\\\\)/;my $resolved=$foreign?$model:resolve_path($model,$base,$b->{root},$^O eq 'MSWin32');push @warnings,'This configuration contains a Windows model path. Review it for this host before saving.' if $foreign;
  if(defined($resolved)){$model=$resolved}else{$model='';push @warnings,'The model path is relative to an unknown working directory. Choose an absolute catalog model path below.';}
 }
 push @warnings,'No model alias was supplied by the configuration. Enter an API model alias above.' unless length($alias);
 for my $field (@{$d->{fields}}){next unless $field->{required} && $field->{binding} eq 'config';my $v=path_value($config,$field->{path});next if defined($v)&&!ref($v)&&length($v);my $default=path_value($d->{new_config}||{},$field->{path});if(defined($default)&&!ref($default)){$default=VisLlama::Engine::Plan::expand($default,{root=>$b->{root},executable=>$b->{executable},runtime_executable=>$b->{runtime_executable}//'',runtime_library_dirs=>$b->{runtime_library_dirs}||[]});next if ref($default)||length($default);}push @warnings,$field->{label}.' is missing; fill it in below.';}
 return {alias=>$alias,model=>$model,warnings=>\@warnings};
}
1;
