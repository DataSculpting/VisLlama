use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Temp qw(tempdir);
use File::Spec;
use Cwd qw(abs_path getcwd);
use Encode qw(decode);
use VisLlama::App ();
use VisLlama::Context qw(%CFG);
use VisLlama::Paths ();
use VisLlama::Template ();
use VisLlama::View ();
use VisLlama::Config ();
use VisLlama::Catalog ();

my $root = abs_path("$RealBin/..");
my $working = getcwd();
my $temp = tempdir(CLEANUP => 1);
chdir $temp or die $!;
is(abs_path(VisLlama::Paths::app_base_dir()), $root, 'Installation path is independent of working directory');
my $html = decode('UTF-8', VisLlama::View::app_html());
like($html, qr/VisLlama 1\.5\.18/, 'Real template renderer supplies the current version');
unlike($html, qr/\{\{(?:[A-Z]|>)/, 'No unresolved template directives');
unlike($html, qr/<style>|<script>/, 'Styles and scripts are loaded as external assets');
like($html, qr{/assets/img/visllama-logo-large\.png}, 'Splash logo uses public asset path');

local $CFG{builds} = {q{Build <&"'>} => 'unused'};
local $CFG{build_order} = [q{Build <&"'>}];
like(VisLlama::View::app_html(), qr{value="Build &lt;&amp;&quot;&#39;&gt;"}, 'Build choices are HTML escaped');

sub put {
    my ($name, $text) = @_;
    open my $fh, '>:encoding(UTF-8)', File::Spec->catfile($temp, $name) or die $!;
    print $fh $text;
    close $fh;
}
put('child.html', '{{NAME}}');
put('page.html', '{{> child.html}}|{{{TRUSTED}}}');
my $templates = VisLlama::Template->new($temp);
is($templates->render('page.html', {NAME=>'<&"\''}, {TRUSTED=>'<b>OK</b>'}),
    '&lt;&amp;&quot;&#39;|<b>OK</b>', 'Includes, escaped values and explicit trusted markup');
is($templates->render('child.html', {NAME=>'{{NAME}}'}), '{{NAME}}', 'Inserted values are not reparsed');
for my $name ('../page.html', '/page.html', 'x\\page.html') {
    eval { $templates->render($name) };
    like($@, qr/Invalid template name/, 'Template traversal rejected');
}
put('loop.html', '{{> loop.html}}');
eval { $templates->render('loop.html') };
like($@, qr/include cycle/, 'Recursive includes rejected');
eval { $templates->render('child.html') };
like($@, qr/Missing template value/, 'Missing values fail explicitly');

# A relocated state directory must keep every legacy filename and JSON shape.
{
    no warnings 'redefine';
    local *VisLlama::Paths::app_base_dir = sub { $temp };
    my $presets = VisLlama::Paths::presets_dir();
    VisLlama::Config::write_json_file_ascii(File::Spec->catfile($presets, 'llama-builds.json'),
        [{alias=>'build-test',path=>'C:\\llama builds\\test'}]);
    VisLlama::Config::write_json_file_ascii(File::Spec->catfile($presets, 'model-root.json'),
        {model_root=>'D:\\GGUF'});
    VisLlama::Config::write_json_file_ascii(File::Spec->catfile($presets, 'build-discovery.json'),
        {root=>'C:\\llama builds'});
    my $service = {host=>'192.168.6.39',port=>18080,models_max=>2,threads_http=>'3',autoload=>0};
    VisLlama::Config::write_json_file_ascii(File::Spec->catfile($presets, 'router-service.json'), $service);
    my $saved = [{alias=>'model-test',build=>'build-test',model=>'D:\\GGUF\\test.gguf',
        enabled=>0,load_on_startup=>1,options=>[['ctx-size','65536']],
        ui=>{routerHost=>'0.0.0.0',customLegacyValue=>'preserve-me'}}];
    VisLlama::Config::write_json_file_ascii(File::Spec->catfile($presets, 'router-presets.json'), $saved);
    my %before;
    for my $name (qw(llama-builds.json model-root.json build-discovery.json router-service.json router-presets.json)) {
        open my $fh, '<:raw', File::Spec->catfile($presets,$name) or die $!;
        $before{$name} = do { local $/; <$fh> };
    }
    VisLlama::Config::load_runtime_configs();
    is_deeply($CFG{build_order}, ['build-test'], 'Existing build order loads');
    is($CFG{model_root}, 'D:\\GGUF', 'Existing model root loads');
    is_deeply(VisLlama::Config::load_router_service_config(), $service, 'Router settings stay authoritative');
    my $loaded = VisLlama::Catalog::load_router_presets();
    is($loaded->[0]{ui}{customLegacyValue}, 'preserve-me', 'Existing UI snapshot fields retained');
    for my $name (sort keys %before) {
        open my $fh, '<:raw', File::Spec->catfile($presets,$name) or die $!;
        is(do { local $/; <$fh> }, $before{$name}, "$name not rewritten by module loading or reads");
    }
}
chdir $working or die $!;
done_testing();
