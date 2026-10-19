# Real directory changes and external draft references through API/preflight/INI.
# Dummy GGUF files verify path propagation, not model validity or MTP inference.
use strict;use warnings;use Test::More;use FindBin qw($RealBin);use lib "$RealBin/../lib";
use File::Temp qw(tempdir);use JSON::PP qw(decode_json);use VisLlama::API::Models ();
use VisLlama::Models ();use VisLlama::PlannerSettings ();use VisLlama::Catalog ();use VisLlama::Preflight ();
use VisLlama::Context qw(%CFG);
my $root=tempdir(CLEANUP=>1);my $target="$root/target.gguf";my $head="$root/external MTP heads.gguf";
sub put {open my $f,'>:raw',$_[0] or die $!;print {$f} 'fixture';close $f;}
put($target);local $CFG{model_root}=$root;local $CFG{builds}={test=>$root};
sub inventory {my $wire='';open my $sock,'>',\$wire or die $!;VisLlama::API::Models::handle($sock,'/api/refresh-models',{});close $sock;my ($body)=$wire=~/\r\n\r\n(.*)/s;return decode_json($body);}
is(scalar @{inventory()->{models}},1,'Initial scan sees target');put($head);
my $scan=inventory();is(scalar @{$scan->{models}},2,'New external head appears on next scan');is($scan->{model_root},$root,'Refresh response identifies its root');
{
 no warnings 'redefine';local *VisLlama::Builds::find_server_exe=sub {$target};
 local *VisLlama::Paths::app_base_dir=sub {$root};
 for my $flag(qw(model-draft spec-draft-model)){
  my $args=['--spec-type','draft-mtp','--'.$flag,$head];
  my $settings=VisLlama::PlannerSettings::from_args({},$args,'',undef);
  is($settings->{draft},$head,'Planner recognizes external head in both option namespaces');
  like($settings->{_unsupported},qr/separate draft model/i,'Calculated planning cannot silently omit external head memory');
  my $preset={alias=>'target',build=>'test',model=>$target,enabled=>1,options=>VisLlama::Catalog::args_to_preset_options($args),ui=>{}};
  VisLlama::Catalog::write_router_ini_for_build([$preset],'test',"$root/router.ini");
  open my $f,'<:raw',"$root/router.ini" or die $!;my $ini=do{local $/;<$f>};close $f;
  like($ini,qr/^\Q$flag\E = \Q$head\E$/m,'Generated INI keeps literal external path');
  like($ini,qr/^spec-type = draft-mtp$/m,'External heads still use MTP decoding');
  my $validated=VisLlama::Preflight::validate({build=>'test',model=>$target,args=>$args,ui=>{}},0,0);
  ok($validated,'External file reference preflight accepts existing head');
  unlink $head;eval {VisLlama::Preflight::validate({build=>'test',model=>$target,args=>$args,ui=>{}},0,0)};
  like($@,qr/referenced model, adapter or chat template file is missing/,'Missing external head fails before native load');put($head);
 }
}
unlink $head;is(scalar @{inventory()->{models}},1,'Deleted external head disappears from scan');
done_testing();
