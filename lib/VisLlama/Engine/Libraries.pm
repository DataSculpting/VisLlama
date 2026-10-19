package VisLlama::Engine::Libraries;
# GPL-3.0-only. Read-only, declarative library lookup; never runs an interpreter.
use strict;use warnings;use File::Spec;use File::Basename qw(dirname);use File::Glob qw(bsd_glob GLOB_NOSORT GLOB_QUOTE);use Cwd qw(abs_path);use JSON::PP ();use Storable qw(dclone);
use VisLlama::Engine::Plan ();
sub rules {
 my ($d)=@_;return $d->{runtime_libraries} if $d->{runtime_libraries};
 # Older definitions already declared this binding through the build placeholder.
 my ($field)=grep {$_->{binding} eq 'config' && $_->{type} eq 'json-array' && (VisLlama::Engine::Plan::get_path($d->{new_config}||{},$_->{path})//'') eq '${runtime_library_dirs}'} @{$d->{fields}};
 return undef unless $field;my $rule={config_path=>$field->{path},interpreter_relative=>[]};
 require VisLlama::Engine::Definitions;my $bundled=eval {VisLlama::Engine::Definitions::bundled($d->{id})};
 if ($bundled && grep {$_ eq ($d->{digest}//'')} @{$bundled->{previous_default_digests}||[]}) {
  my $new=$bundled->{runtime_libraries};$rule=$new if $new && join('/',@{$new->{config_path}}) eq join('/',@{$field->{path}});
 }
 return $rule;
}
sub resolve {
 my ($b,$d,$p)=@_;my $rule=rules($d);my ($dirs,$source,$base)=($b->{runtime_library_dirs}||[],'Build defaults',$b->{root});
 if ($p && $rule) {
  die 'Model discovery context must be an object' unless ref($p) eq 'HASH';
  # Use the existing typed config renderer, without requirements/model binding or
  # launch overrides. Discovery also works before a preset is complete.
  my $view=dclone($d);delete @{$view}{qw(requirements model_bindings config_overrides)};
  $view->{fields}=[grep {$_->{binding} eq 'config' || $_->{binding} eq 'none'} @{$view->{fields}}];delete $_->{required} for @{$view->{fields}};
  my $plan=VisLlama::Engine::Plan::render($view,$b,{%$p,alias=>'discovery',model=>'',settings=>$p->{settings}||{}},'discovery',8081);
  my $value=VisLlama::Engine::Plan::get_path($plan->{config},$rule->{config_path});
  # An explicit omission disables detection; an absent imported key may detect.
  my $omitted=grep {$_->{binding} eq 'config' && join('/',@{$_->{path}}) eq join('/',@{$rule->{config_path}}) && exists($p->{settings}{$_->{key}}) && !defined($p->{settings}{$_->{key}})} @{$view->{fields}};
  if (defined $value || $omitted) {$dirs=$value||[];$source='Imported';$source='User-selected' if grep {exists($p->{settings}{$_->{key}}) && $_->{binding} eq 'config' && join('/',@{$_->{path}}) eq join('/',@{$rule->{config_path}})} @{$view->{fields}};}
  if (!defined(VisLlama::Engine::Plan::get_path($p->{native_config}||{},$rule->{config_path})) && $source ne 'User-selected') {$source='Build defaults';}
  if ($rule->{base_path}) {$base=VisLlama::Engine::Plan::get_path($plan->{config},$rule->{base_path})||$base;}
  $base=File::Spec->rel2abs($base,$b->{root});
  if ($d->{runtime_executable_path}) {my $exe=VisLlama::Engine::Plan::get_path($plan->{config},$d->{runtime_executable_path});die 'The model inference executable differs from this build. Select the matching build before discovering options.' if $exe && (!abs_path(File::Spec->rel2abs($exe,$base)) || (abs_path(File::Spec->rel2abs($exe,$base))//'') ne (abs_path($b->{runtime_executable}//'')//''));}
 }
 die 'Library folders must be a list of directory paths' unless ref($dirs) eq 'ARRAY' && @$dirs<=128 && !grep {!defined($_)||ref($_)||!length($_)||/[\x00-\x1f]/} @$dirs;
 # Empty, explicitly selected model lists mean no extra library search path.
 if (!@$dirs && $source eq 'Build defaults' && $rule) {
  my @found;for my $relative (@{$rule->{interpreter_relative}||[]}) {
   # Escape metacharacters belonging to the installation path, not the rule.
   my $prefix=dirname($b->{executable});$prefix=~s{\\}{/}g if $^O eq 'MSWin32';$prefix=~s/([\\*?\[\]{}])/\\$1/g;
   my $pattern=$prefix.'/'. $relative;
   push @found,sort grep {-d $_} bsd_glob($pattern,GLOB_NOSORT|GLOB_QUOTE);last if @found>128;
  }$dirs=\@found;$source='Detected' if @found;
 }
 $base=File::Spec->rel2abs($base,$b->{root});my %seen;my @folders;
 for my $path (@$dirs) {my $full=File::Spec->rel2abs($path,$base);$full=abs_path($full)||$full;next if $seen{$full}++;push @folders,{path=>$full,source=>$source,exists=>-d $full?JSON::PP::true:JSON::PP::false};}
 return {folders=>\@folders,directories=>[map {$_->{path}} @folders],missing=>[map {$_->{path}} grep {!$_->{exists}} @folders]};
}
sub digest {require Digest::SHA;Digest::SHA::sha256_hex(JSON::PP->new->canonical->encode($_[0]->{directories}))}
1;
