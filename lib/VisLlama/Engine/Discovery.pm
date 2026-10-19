package VisLlama::Engine::Discovery;
# GPL-3.0-only. Bounded declared commands; additions never modify base metadata.
use strict;use warnings;use JSON::PP ();use Digest::SHA qw(sha256_hex);use File::Spec;use Cwd qw(getcwd);use Storable qw(dclone);
use VisLlama::Engine::Libraries ();use VisLlama::Engine::Registry ();use VisLlama::Engine::Definitions ();use VisLlama::Engine::Plan ();use VisLlama::Command ();use VisLlama::Config ();use VisLlama::Errors ();
sub path {
 my ($b)=@_;die 'Invalid registered build ID' unless ($b->{id}//'') =~ /\Aengine-[a-z0-9-]+\z/;
 File::Spec->catfile(VisLlama::Engine::Definitions::directory($b->{engine}),'additive-'.$b->{id}.'.json');
}
sub parse_help {
 my ($text,$q)=@_;my (@fields,@flags,@unmapped,%seen);my %exclude=map {$_=>1} @{$q->{exclude}||[]};
 for my $line (split /\r?\n/,$text) {
  next unless $line =~ /^\s*(?:-[A-Za-z0-9],?\s+)?(--[A-Za-z][\w-]*)(.*)$/;my ($flag,$tail)=($1,$2);next if $seen{$flag}++;
  push @flags,$flag;next if $exclude{$flag};
  # Only unambiguous long-flag help rows become controls. No inferred JSON keys.
  my ($sig,$description)=split /\s{2,}/,$tail,2;$sig//= ''; $sig=~s/^\s+|\s+$//g;
  my $type;
  if ($sig eq '' && defined $description) {$type='boolean'}
  elsif ($sig =~ /\A(?:[<=\[])?(?:INT|INTEGER|N)(?:[>\]])?\z/i) {$type='integer'}
  elsif ($sig =~ /\A(?:[<=\[])?(?:FLOAT|NUMBER)(?:[>\]])?\z/i) {$type='number'}
  elsif ($sig =~ /\A(?:[<=\[])?(?:PATH|FILE|DIR|STRING|VALUE)(?:[>\]])?\z/i) {$type='string'}
  unless ($type) {push @unmapped,$line;next;}
  push @fields,{key=>substr('discovered-'.$q->{id}.'-'.substr($flag,2),0,63),label=>$flag,type=>$type,binding=>$q->{target},flag=>$flag,
    ($q->{target} eq 'config-flag'?(path=>$q->{path}):()),group=>'Discovered build options',source=>'Discovered '.$q->{id}.' --help',description=>$description//'',support=>{probe=>$q->{id},flag=>$flag}};
 }
 return (\@fields,\@flags,\@unmapped);
}
sub parse_schema {
 my ($text,$q)=@_;my $json=JSON::PP::decode_json($text);die 'Discovery schema needs fields array' unless ref($json) eq 'HASH' && ref($json->{fields}) eq 'ARRAY';
 my @fields;
 for my $f (@{$json->{fields}}) {die 'Schema field binding does not match declared target' unless ($f->{binding}//'') eq $q->{target};push @fields,$f;}
 return (\@fields,[map {$_->{flag}} grep {$_->{flag}} @fields],[]);
}
sub run {
 my ($b,$d,$p)=@_;require VisLlama::Engines;my $libraries=VisLlama::Engine::Libraries::resolve($b,$d,$p);die 'Some library folders are missing. Review Native library folders before discovery.' if @{$libraries->{missing}};my $fingerprint=VisLlama::Engines::fingerprint($b);
 my (@fields,@evidence,%flags,%seen);my $cwd=getcwd();
 for my $q (@{$d->{discovery}||[]}) {
  if (grep {/\$\{runtime_executable\}/} @{$q->{argv}}) {next unless length($b->{runtime_executable}//'');}
  my $argv=VisLlama::Engine::Plan::expand($q->{argv},{root=>$b->{root},executable=>$b->{executable},runtime_executable=>$b->{runtime_executable}//''});
  my ($out,$err,$exit,$failure);eval {local %ENV=%ENV;if ($q->{argv}[0] eq '${runtime_executable}' && @{$libraries->{directories}}) {my $key=$^O eq 'MSWin32'?'PATH':'LD_LIBRARY_PATH';$ENV{$key}=join($^O eq 'MSWin32'?';':':',@{$libraries->{directories}},($ENV{$key}||()));}chdir $b->{root} or die 'Cannot enter build directory';local $VisLlama::Command::TIMEOUT=$q->{timeout};local $VisLlama::Command::LIMIT=1048576;$out=VisLlama::Command::capture(1,@$argv);$exit=$?;$err=$VisLlama::Command::LAST_STDERR;1} or $failure=$@;
  chdir $cwd or die 'Cannot restore working directory';
  die 'Engine capability discovery failed. Check the selected executable and Logs / Diagnostics.' . chr(10) . join(chr(10),($failure//''),($err//''),($out//'')) if $failure || $exit;
  my ($found,$advertised,$unmapped)=$q->{parser} eq 'schema-json'?parse_schema($out,$q):parse_help(($out//'')."\n".($err//''),$q);
  push @evidence,{probe=>$q->{id},argv=>$argv,stdout=>$out,stderr=>$err,exit=>$exit,unmapped=>$unmapped};
  $flags{$q->{id}}=$advertised;
  for my $f (@$found) {next if $seen{$f->{key}}++;push @fields,$f;}
 }
 my %base=map {$_->{key}=>1} @{$d->{fields}};my %targets=map {($_->{binding}//'').':'.join('/',@{$_->{path}||[]}).':'.($_->{flag}//'')=>1} @{$d->{fields}};
 @fields=grep {!$base{$_->{key}} && !$targets{($_->{binding}//'').':'.join('/',@{$_->{path}||[]}).':'.($_->{flag}//'')}} @fields;
 my $merged=VisLlama::Engine::Definitions::raw($d);push @{$merged->{fields}},@fields;VisLlama::Engine::Registry::validate($merged);
 die 'Build changed during discovery; retry after installation finishes' unless $fingerprint eq VisLlama::Engines::fingerprint($b);
 VisLlama::Engine::Definitions::ensure_local($d);
 my $record={library_context=>$libraries,library_digest=>VisLlama::Engine::Libraries::digest($libraries),schema_version=>'1.0',build_id=>$b->{id},build_name=>$b->{name},root=>$b->{root},executable=>$b->{executable},runtime_executable=>$b->{runtime_executable},fingerprint=>$fingerprint,definition_digest=>$d->{digest},at=>scalar(gmtime()),fields=>\@fields,flags=>\%flags,evidence=>\@evidence};
 VisLlama::Config::write_json_file_ascii(path($b),$record);return effective($b,$d);
}
sub effective {
 my ($b,$d)=@_;require VisLlama::Engines;
 my $file=path($b);my $record=-f $file?eval {VisLlama::Engine::Registry::read_json($file)}:undef;
 my $valid=$record && ref($record) eq 'HASH' && ($record->{build_id}//'') eq $b->{id} && ($record->{definition_digest}//'') eq $d->{digest} && ($record->{fingerprint}//'') eq VisLlama::Engines::fingerprint($b);
 my $merged=VisLlama::Engine::Definitions::raw($d);my $status=$valid?'current':-f $file?'stale':'not-run';
 if ($record && ref($record->{fields}) eq 'ARRAY') {
  my %base=map {($_->{key}=>1,map {$_=>1} @{$_->{legacy_keys}||[]})} @{$merged->{fields}};
  push @{$merged->{fields}},grep {!$base{$_->{key}}} @{$record->{fields}||[]};
  eval {VisLlama::Engine::Registry::validate($merged)};if($@){$merged=VisLlama::Engine::Definitions::raw($d);$valid=0;$status='invalid';}
 }
 my %flags=$valid?%{$record->{flags}||{}}:();
 my %base_keys=map {$_->{key}=>1} @{$d->{fields}};
 for my $f (@{$merged->{fields}}) {if(!$base_keys{$f->{key}}){$f->{available}=$valid?JSON::PP::true:JSON::PP::false;$f->{unavailable_reason}='Discovery is stale; discover this installed build again.' unless $valid;}next unless $f->{support};my $q=$f->{support};if($q->{advisory}) {my $advertised=$valid && grep {$_ eq $q->{flag}} @{$flags{$q->{probe}}||[]};$f->{available}=JSON::PP::true;$f->{support_notice}=$advertised?'Advertised by this installed build.':$valid?'Not advertised by this build; check its documentation before using.':'Known definition option; installed-build support has not been checked. Discovery is optional.';next;}$f->{available}=($valid && grep {$_ eq $q->{flag}} @{$flags{$q->{probe}}||[]})?JSON::PP::true:JSON::PP::false;$f->{unavailable_reason}=$valid?'Not advertised by this installed build.':'Discover capabilities for this build to verify this option.' unless $f->{available};my ($source)=grep {$_->{id} eq $q->{probe}} @{$d->{discovery}||[]};$f->{unavailable_reason}='Set the native executable in Manage builds, then Discover options.' if !$f->{available} && $source && $source->{argv}[0] eq '${runtime_executable}' && !length($b->{runtime_executable}//'');}
 return {%$merged,(VisLlama::Engine::Libraries::rules($d)?(runtime_libraries=>VisLlama::Engine::Libraries::rules($d)):()),digest=>$d->{digest},definition_file=>$d->{definition_file},default_controls_available=>$d->{default_controls_available}||0,bundled_definition_version=>$d->{bundled_definition_version},capabilities=>{status=>$status,file=>$file,at=>$valid?$record->{at}:undef,library_digest=>$valid?$record->{library_digest}:undef,library_context=>$valid?$record->{library_context}:undef,added_fields=>$valid?scalar(@{$record->{fields}}):0,fingerprint=>$valid?$record->{fingerprint}:undef},additive_digest=>$valid?sha256_hex(VisLlama::Engine::Registry::json()->encode($record)):''};
}
1;
