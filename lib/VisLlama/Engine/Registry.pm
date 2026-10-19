package VisLlama::Engine::Registry;
# GPL-3.0-only. Definitions describe a compatible engine family, never a host path.
use strict;
use warnings;
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use File::Spec;
use Cwd qw(abs_path);
use VisLlama::Paths ();
use VisLlama::Errors ();
sub json { JSON::PP->new->utf8->canonical }
sub read_json {
    my ($path)=@_;die 'Engine JSON file is missing or too large' unless -f $path && -s $path<=1048576;
    open my $fh,'<:raw',$path or die "Cannot read engine JSON: $!";local $/;my $bytes=<$fh>;close $fh;
    return json()->decode($bytes);
}
sub keys_only {
    my ($v,@keys)=@_;die 'Expected engine metadata object' unless ref($v) eq 'HASH';
    my %allowed=map {$_=>1} @keys;die 'Unknown engine metadata key: '.$_ for grep {!$allowed{$_}} keys %$v;
}
sub id {defined($_[0]) && !ref($_[0]) && $_[0] =~ /\A[a-z][a-z0-9-]{0,63}\z/}
sub scalar_text {defined($_[0]) && !ref($_[0]) && length($_[0])<=8192 && $_[0]!~/[\x00-\x08\x0b\x0c\x0e-\x1f]/}
sub pointer {
    my ($p)=@_;die 'Invalid configuration field path' unless ref($p) eq 'ARRAY' && @$p && @$p<16 && !grep {!scalar_text($_)||!length($_)||/\A(?:__proto__|constructor|prototype)\z/} @$p;
}
sub validate {
    my ($d)=@_;
    keys_only($d,qw(schema_version definition_version id name description platforms driver argv probe fields config_overrides readiness concurrency evidence fingerprint_files new_config model_bindings discovery requirements compatible_definition_digests runtime_executable_path previous_default_digests ui runtime_libraries));
    die 'Unsupported engine schema version' unless ($d->{schema_version}//'') =~ /\A1\.[01]\z/;
    die 'Invalid engine definition identity' unless id($d->{id}) && $d->{id} ne 'llamacpp' && scalar_text($d->{name}) && ($d->{definition_version}//'') =~ /\A\d+\.\d+\.\d+\z/;
    die 'Unsupported engine driver' unless ($d->{driver}//'') =~ /\A(?:native-json|native-cli)\z/;
    die 'Invalid supported platforms' unless ref($d->{platforms}) eq 'ARRAY' && @{$d->{platforms}} && !grep {$_ ne 'windows' && $_ ne 'linux'} @{$d->{platforms}};
    die 'Invalid engine argv' unless ref($d->{argv}) eq 'ARRAY' && @{$d->{argv}} && $d->{argv}[0] eq '${executable}' && !grep {!scalar_text($_)} @{$d->{argv}};
    if ($d->{probe}) {
        keys_only($d->{probe},qw(argv required_flags timeout));
        die 'Invalid engine probe' unless ref($d->{probe}{argv}) eq 'ARRAY' && $d->{probe}{argv}[0] eq '${executable}' && !grep {!scalar_text($_)} @{$d->{probe}{argv}};
        die 'Invalid probe flags' unless ref($d->{probe}{required_flags}) eq 'ARRAY' && !grep {!scalar_text($_)||!/^--[\w-]+$/} @{$d->{probe}{required_flags}};
        die 'Invalid probe timeout' unless ($d->{probe}{timeout}//0)=~/^\d+$/ && $d->{probe}{timeout}>=1 && $d->{probe}{timeout}<=15;
    }
    die 'Invalid engine fields' unless ref($d->{fields}) eq 'ARRAY' && @{$d->{fields}}<=128;
    my %seen;
    for my $f (@{$d->{fields}}) {
        keys_only($f,qw(key label description type minimum maximum enum binding flag path name source required when initial support file_kind group format clear_flags legacy_keys));
        die 'Invalid or duplicate field' unless id($f->{key}) && !$seen{$f->{key}}++ && scalar_text($f->{label});
        die 'Unsupported field type' unless ($f->{type}//'') =~ /\A(?:string|integer|number|boolean|json-array)\z/;
        die 'Unsupported field binding' unless ($f->{binding}//'') =~ /\A(?:flag|config|environment|config-flag|none)\z/;
        pointer($f->{path}) if $f->{binding} eq 'config' || $f->{binding} eq 'config-flag';
        die 'Invalid option flag' if ($f->{binding} eq 'flag' || $f->{binding} eq 'config-flag') && ($f->{flag}//'') !~ /\A--[a-zA-Z][\w-]*\z/;
        die 'Invalid environment field' if $f->{binding} eq 'environment' && ($f->{name}//'') !~ /\A[A-Z][A-Z0-9_]*\z/;
        for my $bound (qw(minimum maximum)) {die 'Invalid numeric bound' if exists($f->{$bound}) && (!scalar_text($f->{$bound}) || $f->{$bound}!~/\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/ || abs($f->{$bound})>=1e15);}
        die 'Reversed numeric bounds' if defined($f->{minimum}) && defined($f->{maximum}) && $f->{minimum}>$f->{maximum};
        die 'Invalid enum' if exists($f->{enum}) && (ref($f->{enum}) ne 'ARRAY' || grep {!scalar_text($_)} @{$f->{enum}});
    }
    validate_extensions($d);
    die 'Invalid config overrides' if exists($d->{config_overrides}) && ref($d->{config_overrides}) ne 'HASH';
    keys_only($d->{readiness},qw(path equals));
    die 'Invalid local readiness path' unless ($d->{readiness}{path}//'') =~ m{\A/[A-Za-z0-9_/-]+\z} && $d->{readiness}{path}!~/\.\./;
    die 'Readiness requires an explicit JSON predicate' unless ref($d->{readiness}{equals}) eq 'HASH' && keys %{$d->{readiness}{equals}};
    die 'Invalid concurrency policy' unless ($d->{concurrency}//'') =~ /\A(?:independent|unverified|single-instance)\z/;
    if ($d->{fingerprint_files}) {
        die 'Invalid fingerprint files' unless ref($d->{fingerprint_files}) eq 'ARRAY' && !grep {!scalar_text($_)||!m{\A[A-Za-z0-9_./-]+\z}||m{(?:\A/|(?:\A|/)\.\.(?:/|\z))}} @{$d->{fingerprint_files}};
    }
    return $d;
}
sub validate_ui {
 my ($ui)=@_;keys_only($ui,qw(build_fields import));
 if($ui->{build_fields}){keys_only($ui->{build_fields},qw(executable runtime_executable));for my $entry(values %{$ui->{build_fields}}){keys_only($entry,qw(label description placeholder));die 'Invalid build field presentation' if grep {!scalar_text($entry->{$_})} keys %$entry;}}
 if($ui->{import}){my $i=$ui->{import};keys_only($i,qw(alias_path base_path model_paths));pointer($i->{alias_path}) if $i->{alias_path};pointer($i->{base_path}) if $i->{base_path};die 'Invalid import model rules' if exists($i->{model_paths}) && (ref($i->{model_paths}) ne 'ARRAY'||@{$i->{model_paths}}>16);for my $rule(@{$i->{model_paths}||[]}){keys_only($rule,qw(path flag));pointer($rule->{path});die 'Invalid import model flag' if $rule->{flag} && $rule->{flag}!~/\A--[a-zA-Z][\w-]*\z/;}}
}
sub validate_extensions {
 my ($d)=@_;validate_ui($d->{ui}) if $d->{ui};
 if ($d->{runtime_libraries}) {
  my $l=$d->{runtime_libraries};keys_only($l,qw(config_path base_path interpreter_relative));pointer($l->{config_path});pointer($l->{base_path}) if $l->{base_path};
  die 'Invalid library detection rules' unless ref($l->{interpreter_relative}) eq 'ARRAY' && @{$l->{interpreter_relative}}<=16 && !grep {!scalar_text($_)||!m{\A(?:\.\./){0,4}[A-Za-z0-9_*/.-]+\z}||m{(?:/\.\./|//)}} @{$l->{interpreter_relative}};
 }
 my %field_keys=map {$_->{key}=>1} @{$d->{fields}};
 for my $f (@{$d->{fields}}) {
  die 'Invalid required-field marker' if exists($f->{required}) && !JSON::PP::is_bool($f->{required});
  if ($f->{when}) {keys_only($f->{when},qw(key equals));die 'Invalid field dependency' unless id($f->{when}{key}) && $field_keys{$f->{when}{key}} && (scalar_text($f->{when}{equals}) || JSON::PP::is_bool($f->{when}{equals}));}
  if ($f->{support}) {keys_only($f->{support},qw(probe flag advisory));die 'Invalid advisory marker' if exists($f->{support}{advisory}) && !JSON::PP::is_bool($f->{support}{advisory});die 'Invalid support predicate' unless id($f->{support}{probe}) && ($f->{support}{flag}//'') =~ /\A--[\w-]+\z/;}
  die 'Invalid legacy control keys' if $f->{legacy_keys} && (ref($f->{legacy_keys}) ne 'ARRAY' || grep {!id($_)} @{$f->{legacy_keys}});
  die 'Invalid control group' if exists($f->{group}) && !scalar_text($f->{group});
  die 'Invalid string format' if $f->{format} && $f->{format}!~/\A(?:integer-csv|auto-or-integer-csv)\z/;
  for my $flag (@{$f->{clear_flags}||[]}) {keys_only($flag,qw(flag takes_value path));pointer($flag->{path}) if $flag->{path};die 'Invalid replaced flag' unless ($flag->{flag}//'') =~ /\A--[\w-]+\z/ && JSON::PP::is_bool($flag->{takes_value});}
  die 'Invalid file selector' if $f->{file_kind} && $f->{file_kind}!~/\A(?:file|directory)\z/;
 }
 pointer($d->{runtime_executable_path}) if $d->{runtime_executable_path};
 die 'Invalid new configuration template' if exists($d->{new_config}) && ref($d->{new_config}) ne 'HASH';
 for my $m (@{$d->{model_bindings}||[]}) {die 'Invalid model path kind' if $m->{kind} && $m->{kind}!~/\A(?:file|directory)\z/;keys_only($m,qw(key equals path flag kind preserve_existing));die 'Invalid model preservation marker' if exists($m->{preserve_existing}) && !JSON::PP::is_bool($m->{preserve_existing});die 'Invalid model binding' unless id($m->{key}) && scalar_text($m->{equals}) && ($m->{flag}//'')=~/\A--[\w-]+\z/;pointer($m->{path});}
 for my $q (@{$d->{requirements}||[]}) {keys_only($q,qw(path kind label children));pointer($q->{path});die 'Invalid required files' if $q->{children} && (ref($q->{children}) ne 'ARRAY' || grep {!/\A[\w.-]+\z/ || /^\.\.?$/} @{$q->{children}});die 'Invalid requirement' unless ($q->{kind}//'')=~/\A(?:file|directory|array)\z/ && scalar_text($q->{label});}
 my %probe_ids;
 for my $q (@{$d->{discovery}||[]}) {
  keys_only($q,qw(id argv timeout parser target path exclude));
  die 'Invalid discovery identity' unless id($q->{id}) && !$probe_ids{$q->{id}}++;
  die 'Invalid discovery parser' unless ($q->{parser}//'') =~ /\A(?:help|schema-json)\z/;
  die 'Invalid discovery target' unless ($q->{target}//'') =~ /\A(?:flag|config-flag|config)\z/;
  pointer($q->{path}) if $q->{target} eq 'config-flag';
  die 'JSON config discovery needs machine-readable schema' if $q->{target} eq 'config' && $q->{parser} ne 'schema-json';
  die 'Invalid discovery argv' unless ref($q->{argv}) eq 'ARRAY' && @{$q->{argv}} && ($q->{argv}[0] eq '${executable}' || $q->{argv}[0] eq '${runtime_executable}') && !grep {!scalar_text($_)} @{$q->{argv}};
  die 'Invalid discovery timeout' unless ($q->{timeout}//0)=~/^\d+$/ && $q->{timeout}>=1 && $q->{timeout}<=15;
  die 'Invalid discovery exclusions' if $q->{exclude} && (ref($q->{exclude}) ne 'ARRAY' || grep {!/^--[\w-]+$/} @{$q->{exclude}});
 }
 for my $f (@{$d->{fields}}) {die 'Field support references an unknown discovery probe' if $f->{support} && !$probe_ids{$f->{support}{probe}};}
 for (@{$d->{compatible_definition_digests}||[]},@{$d->{previous_default_digests}||[]}) {die 'Invalid compatible digest' unless /^[0-9a-f]{64}$/;}
}
sub roots { (File::Spec->catdir(VisLlama::Paths::app_base_dir(),'engines'),File::Spec->catdir(VisLlama::Paths::presets_dir(),'engines')) }
sub list {
    my (@items,@errors,%seen,%bundled);
    for my $root (roots()) {
        next unless -d $root;opendir my $dh,$root or next;my @dirs=sort grep {id($_)} readdir($dh);closedir $dh;
        for my $id (@dirs) {
            my $item=eval {
                my $duplicate=$seen{$id}++;
                if ($duplicate) {my $marker=File::Spec->catfile($root,$id,'origin.json');my $origin=-f $marker?read_json($marker):{};die 'Duplicate engine definition ID' unless ($origin->{id}//'') eq $id && ($origin->{source}//'') eq 'bundled' && ($origin->{digest}//'') =~ /\A[0-9a-f]{64}\z/;}
                @items=grep {$_->{id} ne $id} @items if $duplicate;
                my $dir=File::Spec->catdir($root,$id);my $file=File::Spec->catfile($dir,'engine.json');
                die 'Engine package escapes its directory' unless VisLlama::Paths::canonical_under($file,$root);
                my $d=validate(read_json($file));die 'Engine directory and ID disagree' unless $d->{id} eq $id;
                my $hash=sha256_hex(json()->encode($d));$bundled{$id}=$d if $root eq (roots())[0];+{%$d,digest=>$hash,definition_file=>$file};
            };
            if ($@) {push @errors,{id=>$id,message=>'Engine definition is invalid or ambiguous.',reference=>VisLlama::Errors::report($@,'configuration_error')};} else {push @items,$item;}
        }
    }
    # Ambiguous IDs never select whichever directory happened to be visited first.
    my %bad=map {$_->{id}=>1} @errors;@items=grep {!$bad{$_->{id}}} @items;
    for my $d (@items) {next unless $bundled{$d->{id}};my %keys=map {$_->{key}=>1} @{$d->{fields}};$d->{default_controls_available}=scalar grep {!$keys{$_->{key}}} @{$bundled{$d->{id}}{fields}};$d->{default_controls_available}++ if !$d->{runtime_libraries} && $bundled{$d->{id}}{runtime_libraries};$d->{bundled_definition_version}=$bundled{$d->{id}}{definition_version};}
    return {definitions=>\@items,errors=>\@errors};
}
sub get {my ($id)=@_;my ($d)=grep {$_->{id} eq ($id//'')} @{list()->{definitions}};die 'Engine definition is missing or invalid' unless $d;return $d;}
1;
