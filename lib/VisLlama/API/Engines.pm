package VisLlama::API::Engines;
# GPL-3.0-only. Explicit optional-engine operations; no implicit probe on Save.
use strict;
use warnings;
use VisLlama::Engines ();
use VisLlama::Engine::Registry ();
use VisLlama::Engine::Import ();
use VisLlama::Engine::Libraries ();
use VisLlama::Engine::Definitions ();
use VisLlama::Context qw($STATE);
use VisLlama::HTTP ();
use VisLlama::Storage ();
use VisLlama::Util qw(jtrue);
sub handle {
    my ($sock,$path,$r)=@_;my $result;
    if ($path eq '/api/engine-list') {$result={%{VisLlama::Engine::Registry::list()},builds=>VisLlama::Engines::builds()};}
    elsif ($path eq '/api/engine-build-save') {$result=VisLlama::Storage::with_lock(sub {{build=>VisLlama::Engines::save_build($r),builds=>VisLlama::Engines::builds()}});}
    elsif ($path eq '/api/engine-build-delete') {VisLlama::Storage::with_lock(sub {VisLlama::Engines::delete_build($r->{id})});$result={builds=>VisLlama::Engines::builds()};}
    elsif ($path eq '/api/engine-import-inspect') {my $b=VisLlama::Engines::build($r->{id});$result={inspection=>VisLlama::Engine::Import::inspect(VisLlama::Engines::definition($b),$b,$r->{native_config})};}
    elsif ($path eq '/api/engine-capabilities') {my $b=VisLlama::Engines::build($r->{id});$result={definition=>VisLlama::Engines::capabilities($b)};}
    elsif ($path eq '/api/engine-library-folders') {my $b=$r->{id}?VisLlama::Engines::build($r->{id}):{root=>$r->{root},executable=>$r->{executable},runtime_library_dirs=>[]};my $d=$r->{id}?VisLlama::Engines::definition($b):VisLlama::Engine::Registry::get($r->{engine});my $l=VisLlama::Engine::Libraries::resolve($b,$d,$r->{model_context});if (!$r->{id} && ref($r->{runtime_library_dirs}) eq 'ARRAY' && @{$r->{runtime_library_dirs}}) {my $selected=VisLlama::Engine::Libraries::resolve({%$b,runtime_library_dirs=>$r->{runtime_library_dirs}},$d);my %seen;my @folders=grep {!$seen{$_->{path}}++} (@{$selected->{folders}},@{$l->{folders}});$_->{source}='User-selected' for @{$selected->{folders}};$l={folders=>\@folders,directories=>[map {$_->{path}} @folders],missing=>[map {$_->{path}} grep {!$_->{exists}} @folders]};}$result={libraries=>$l};}
    elsif ($path eq '/api/engine-discover') {$result={definition=>VisLlama::Engines::discover($r->{id},$r->{model_context})};}
    elsif ($path eq '/api/engine-definition-defaults') {$result={definition=>VisLlama::Engine::Definitions::bundled($r->{id})};}
    elsif ($path eq '/api/engine-definition-save') {
        die 'Stop Router before editing this engine definition' if grep {($_->{engine}//'') eq ($r->{id}//'')} values %{$STATE->{router_engines}||{}};
        $result=VisLlama::Storage::with_lock(sub {{definition=>VisLlama::Engine::Definitions::save($r->{id},$r->{definition},$r->{expected_digest})}});
    }
    elsif ($path eq '/api/engine-probe') {$result=VisLlama::Engines::probe($r->{id});}
    elsif ($path eq '/api/engine-preset-save') {$result=VisLlama::Storage::with_lock(sub {{presets=>VisLlama::Engines::save_preset($r)}});}
    elsif ($path eq '/api/engine-load-check') {my $b=VisLlama::Engines::build($r->{build});VisLlama::Engines::validate_preset({%$r,engine=>$b->{engine}},1);$result={};}
    elsif ($path eq '/api/engine-preview') {$result={plan=>VisLlama::Engines::preview($r)};}
    else {return VisLlama::HTTP::fail_json($sock,'Unknown engine operation',404);}
    return VisLlama::HTTP::json_response($sock,200,{ok=>jtrue,%$result});
}
1;
