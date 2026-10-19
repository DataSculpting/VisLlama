package VisLlama::Engine::Definitions;
# GPL-3.0-only. Explicit, upgrade-safe editable copies; never write bundled files.
use strict;use warnings;use File::Spec;use File::Path qw(make_path);use Storable qw(dclone);
use VisLlama::Engine::Registry ();use VisLlama::Config ();use VisLlama::Paths ();
sub directory {my ($id)=@_;die 'Invalid engine ID' unless VisLlama::Engine::Registry::id($id);File::Spec->catdir(VisLlama::Paths::presets_dir(),'engines',$id)}
sub raw {my $d=dclone($_[0]);delete @{$d}{qw(digest definition_file default_controls_available bundled_definition_version)};return $d}
sub bundled {my ($id)=@_;die 'Invalid engine ID' unless VisLlama::Engine::Registry::id($id);my $file=File::Spec->catfile(VisLlama::Paths::app_base_dir(),'engines',$id,'engine.json');die 'Bundled definition is unavailable' unless VisLlama::Paths::canonical_under($file,File::Spec->catdir(VisLlama::Paths::app_base_dir(),'engines'));return VisLlama::Engine::Registry::validate(VisLlama::Engine::Registry::read_json($file));}
sub save {
 my ($id,$value,$expected)=@_;my $old=VisLlama::Engine::Registry::get($id);
 die 'Engine definition changed; refresh before saving' unless ($expected//'') eq $old->{digest};
 my $d=eval {VisLlama::Engine::Registry::validate(raw($value))};die 'Engine definition is invalid. Review its JSON fields and docs/ENGINES.md.'.chr(10).$@ if $@;die 'Engine identity cannot change' unless $id eq $d->{id};
 my $dir=directory($id);make_path($dir,{mode=>0700});
 die 'Engine definition directory is outside presets' unless VisLlama::Paths::canonical_under($dir,VisLlama::Paths::presets_dir());
 my $marker=File::Spec->catfile($dir,'origin.json');
 VisLlama::Config::write_json_file_ascii($marker,{id=>$id,source=>'bundled',digest=>$old->{digest}}) unless -f $marker;
 VisLlama::Config::write_json_file_ascii(File::Spec->catfile($dir,'engine.json'),$d);
 return VisLlama::Engine::Registry::get($id);
}
sub ensure_local {
 my ($d)=@_;my $local=File::Spec->catfile(directory($d->{id}),'engine.json');
 return $d if ($d->{definition_file}//'') eq $local;
 return save($d->{id},raw($d),$d->{digest});
}
1;
