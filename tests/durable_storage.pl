# Fault injection for publication/recovery. Linux filesystem evidence does not
# validate native Windows rename, antivirus sharing or power-loss behavior.
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);
use JSON::PP ();
use Encode qw(decode);
use VisLlama::Platform ();
BEGIN { no warnings 'redefine'; *VisLlama::Platform::windows=sub {1}; }
use VisLlama::Storage ();
use VisLlama::Config ();
use VisLlama::Catalog ();
use VisLlama::API ();
use VisLlama::Context qw(%CFG);
my $dir=tempdir(CLEANUP=>1);
no warnings 'redefine';
local *VisLlama::Paths::presets_dir=sub {$dir};
local *VisLlama::Paths::app_base_dir=sub {$dir};
my ($a,$b)=("$dir/a.json","$dir/b.ini");
VisLlama::Storage::transaction([[$a,'old-a'],[$b,'old-b']]);
my $replace=\&VisLlama::Storage::replace_file;
{
 my $failed=0;
 local *VisLlama::Storage::replace_file=sub {
  die "Injected second publication failure\n" if $_[1] eq $b && !$failed++;
  $replace->(@_);
 };
 eval {VisLlama::Storage::transaction([[$a,'new-a'],[$b,'new-b']])};
 like($@,qr/Injected/,'Publication failure is reported');
 is(VisLlama::Storage::read($a),'old-a','First published file rolled back');
 is(VisLlama::Storage::read($b),'old-b','Second file preserved');
 ok(!-f VisLlama::Storage::journal_path(),'Successful rollback removes journal');
}
{
 my $calls=0;
 local *VisLlama::Storage::replace_file=sub {
  die "Injected disk failure\n" if $_[1] eq $b || ($_[1] eq $a && $calls++>0);
  $replace->(@_);
 };
 eval {VisLlama::Storage::transaction([[$a,'next-a'],[$b,'next-b']])};
 like($@,qr/recovery incomplete/,'Rollback failure fails closed');
 ok(-f VisLlama::Storage::journal_path(),'Journal retained for later recovery');
}
is(VisLlama::Storage::read($a),'old-a','Next cooperating read recovers interrupted generation');
is(VisLlama::Storage::read($b),'old-b','Recovery restores the complete set');
# Emulate a crash after installation but before the commit marker is removed.
my $backup=VisLlama::Storage::stage($a,'old-a');
VisLlama::Storage::atomic_bytes(VisLlama::Storage::journal_path(),JSON::PP->new->encode({files=>[{path=>$a,backup=>$backup}]}));
VisLlama::Storage::atomic_bytes($a,'uncommitted');
is(VisLlama::Storage::read($a),'old-a','Crash journal rolls back before exposing JSON');
VisLlama::Config::write_json_file_ascii($a,{path=>"C:\\Models\\\x{4e2d}",value=>42});
is(VisLlama::Config::read_json_file($a,{})->{path},"C:\\Models\\\x{4e2d}",'Unicode Windows path round-trips');
VisLlama::Storage::write($a,'{broken');
eval {VisLlama::Config::read_json_file($a,{})};like($@,qr/Invalid saved JSON/,'Corrupt configuration never silently becomes defaults');
my $lock=VisLlama::Storage::controller_lock();
eval {VisLlama::Storage::controller_lock()};like($@,qr/Another VisLlama/,'Second controller cannot own the same installation');
undef $lock;ok(VisLlama::Storage::controller_lock(),'Ownership released with handle, not stale timestamp');
# Contract-test the explicit Unicode native call without claiming Windows execution.
{
 local $INC{'Win32API/File.pm'}=__FILE__;
 local *Win32API::File::MoveFileExW=sub {is(decode('UTF-16LE',$_[0]),"C:\\\x{4e2d}\\source\0",'Wide source path');is(decode('UTF-16LE',$_[1]),"C:\\\x{4e2d}\\dest\0",'Wide destination path');is($_[2],9,'Replace-existing and write-through flags');return 1;};
 VisLlama::Storage::windows_replace("C:\\\x{4e2d}\\source","C:\\\x{4e2d}\\dest");
}
# Catalog publication failure must roll back both authoritative JSON and INIs.
{
 local *VisLlama::Catalog::write_router_ini_for_build=sub {VisLlama::Storage::atomic_bytes($_[2],"version = 1\nnew\n");return {}};
 my $ini="$dir/router-models-build.ini";my ($catalog)=VisLlama::Catalog::router_paths();
 VisLlama::Storage::transaction([[$ini,'old-ini'],[$catalog,'[]']]);my $failed=0;
 local *VisLlama::Storage::replace_file=sub {die "catalog publish failure\n" if $_[1] eq $catalog && !$failed++;$replace->(@_)};
 eval {VisLlama::Catalog::save_router_presets([{alias=>'model',build=>'build',enabled=>1,ui=>{},options=>[]}])};
 like($@,qr/catalog publish failure/,'Catalog commit failure reported');
 is(VisLlama::Storage::read($ini),'old-ini','Derived INI restored with catalog');
 is(VisLlama::Storage::read($catalog),'[]','Authoritative catalog retained');
}
# Renaming a referenced build is one generation, not an earlier standalone save.
{
 my ($build_file)=VisLlama::Config::runtime_config_paths();my ($catalog)=VisLlama::Catalog::router_paths();
 my $exe="$dir/llama-server.exe";open my $ef,'>',$exe or die $!;print {$ef} 'fixture';close $ef;
 local $CFG{builds}={before=>$dir};local $CFG{build_order}=['before'];
 my $old=JSON::PP->new->encode([{alias=>'model',build=>'before',enabled=>1,ui=>{build=>'before'},options=>[]}]);
 VisLlama::Storage::transaction([[$build_file,'[{"alias":"before"}]'],[$catalog,$old],["$dir/router-models-before.ini",'before-ini']]);
 local *VisLlama::Catalog::write_router_ini_for_build=sub {VisLlama::Storage::atomic_bytes($_[2],"after-ini");return {}};
 my $failed=0;local *VisLlama::Storage::replace_file=sub {die "build commit failure\n" if $_[1] eq $build_file && !$failed++;$replace->(@_)};
 my $wire='';open my $sock,'>',\$wire or die $!;
 eval {VisLlama::API::handle_api($sock,'/api/build-save',{old_alias=>'before',alias=>'after',path=>$dir})};close $sock;
 like($@,qr/build commit failure/,'Build rename commit failure propagates');
 is(VisLlama::Storage::read($catalog),$old,'Build rename restores original catalog');
 is(VisLlama::Storage::read("$dir/router-models-before.ini"),'before-ini','Deleted old build INI is restored');
 ok(!-f "$dir/router-models-after.ini",'Uncommitted renamed INI is removed');
 ok(exists $CFG{builds}{before} && !exists $CFG{builds}{after},'Speculative in-memory build mapping is restored');
}
done_testing();
