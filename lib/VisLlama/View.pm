package VisLlama::View;

# Bridge private templates to HTTP, supplying page data and asset versioning.
# The template engine escapes ordinary values; only explicitly trusted HTML bypasses it.
use strict;
use warnings;
use Encode qw(encode);
use File::Spec;
use VisLlama::Context qw($APP_VERSION %CFG);
use VisLlama::Paths ();
use VisLlama::Platform ();
use VisLlama::Template ();
use VisLlama::Util ();

# Render private templates with escaped values and trusted build-option markup.
# Encode once to UTF-8 bytes before HTTP calculates Content-Length.
sub app_html {
    my $templates = VisLlama::Template->new(
        File::Spec->catdir(VisLlama::Paths::app_base_dir(), 'templates'));
    my $build_options = join('', map {
        my $name = VisLlama::Util::html_escape($_);
        qq{<option value="$name">$name</option>}
    } grep { exists $CFG{builds}{$_} } @{$CFG{build_order} || []});
    return encode('UTF-8', $templates->render('app.html',
        { APP_VERSION => $APP_VERSION, SERVER_EXECUTABLE=>VisLlama::Platform::server_name(), FOLDER_ROOTS_LABEL=>VisLlama::Platform::windows()?'Drives':'Roots' }, { BUILD_OPTIONS => $build_options }));
}

1;
