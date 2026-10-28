# GPL-3.0-only. Windows path branch exercised against a synthetic filesystem.
# This does not claim native Windows filesystem validation.
use strict;use warnings;use Test::More;use FindBin qw($RealBin);use lib "$RealBin/../lib";
use File::Temp qw(tempdir);use Cwd qw(getcwd);use VisLlama::Models ();
if($^O eq 'MSWin32'){plan skip_all=>'Synthetic drive-name directories require a POSIX filesystem';}
my $root=tempdir(CLEANUP=>1);my $cwd=getcwd();chdir $root or die $!;
mkdir 'C:\\' or die $!;
no warnings 'redefine';local *VisLlama::Platform::windows=sub {1};
for my $path ('C:','C:\\','C:/'){
 my $listed=VisLlama::Models::list_server_folders($path,1);
 ok($listed,"Can browse $path");is($listed->{path},'C:\\','Returned root includes trailing separator');is($listed->{parent},'','Drive root parent returns to server roots');
}
my $roots=VisLlama::Models::list_server_folders('',0);is_deeply($roots->{folders},[{name=>'C:\\',path=>'C:\\'}],'Drive enumeration uses absolute root paths');
chdir $cwd or die $!;done_testing();
