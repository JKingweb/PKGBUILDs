#!/usr/bin/perl

use FindBin;
use Mojolicious;
use Mojo::File 'path';
use Mojo::Log;
use Mojo::Util;

use warnings;
use strict;
use utf8;

my @vcs_0_variant_suffixes = (qw(git svn hg));
my @cfg_0_variant_suffixes = (qw(static static-compat));
my @cfg_1_variant_suffixes = (qw(doc test cli angle dynamic opengl noopengl));
my @variant_suffixes       = (\@vcs_0_variant_suffixes, \@cfg_0_variant_suffixes, \@cfg_1_variant_suffixes);

sub is_outdated {
    my ($source_path, $target_path) = @_;

    my $source_last_modified = (stat($source_path))[9];
    my $target_last_modified = (stat($target_path))[9];
    return !defined $target_last_modified || $source_last_modified > $target_last_modified;
}

my $log = Mojo::Log->new;
my $mojolicious = Mojolicious->new;
my $renderer = $mojolicious->renderer;
my $pkgbuilds_dir = path($FindBin::Bin, '..', '..')->realpath;
my @template_paths = ("$FindBin::Bin/templates", $pkgbuilds_dir);

$log->level($ENV{LOG_LEVEL} // 'info');
$mojolicious->log($log);
$renderer->paths(\@template_paths);
$log->debug("Template paths:\n" . join("\n", @template_paths));

my $filter_regex      = $ARGV[0];
my $install_directory = $ARGV[1] // $pkgbuilds_dir;
unless (-d $install_directory) {
    $log->error("Output directory '$install_directory' does not exist.");
    exit(-1);
}

# add helper to render Qt dependencies
sub _render_deps {
    my ($package_prefix, $controller, @d) = @_;
    my $prefix = $controller->stash('package_name_prefix');
    my $suffix = $controller->stash('package_name_suffix');
    my $quote  = $prefix =~ qr/^(mingw-w64|android)/ ? "'" : '';
    return join(' ', map { "${quote}${prefix}${package_prefix}-${_}${suffix}${quote}" } @d);
}
sub _render_optdeps {
    my ($package_prefix, $controller, %d) = @_;
    my $prefix = $controller->stash('package_name_prefix');
    my $suffix = $controller->stash('package_name_suffix');
    return join(' ', map { "'${prefix}${package_prefix}-${_}${suffix}: $d{$_}'" } sort keys %d);
}
for my $qt_version (qw(qt5 qt6)) {
    $mojolicious->helper("${qt_version}deps" => sub { _render_deps($qt_version, @_) });
    $mojolicious->helper("${qt_version}optdeps" => sub { _render_optdeps($qt_version, @_) });
}

# add helper to expand pkg-config style libraries into full paths for use with CMake
# example: "-lfoo -lbar" => "/usr/lib/foo.a;/usr/lib/bar.a"
$mojolicious->helper(expand_libs => sub {
    my $controller = shift;
    my $prefix     = $controller->stash('install_prefix');
    my $extension  = $controller->stash('library_extension');
    return join(';', map {
        my $library_name = $_;
        $library_name = $1 if $library_name =~ qr/\w*-l(.*)\w*/;
        "$prefix/lib/lib$library_name.$extension";
    } @_);
});

# define revisions of Qt modules from KDE fork
my %kde_fork_revisions = (
    # module => [rev, 'commit on KDE fork', 'version bump to be reverted'],
    activeqt => [0, '014285857ef1cfb2d9965cf7bad871bbc336ce60'],
    winextras => [0, 'e6a85ae3306867400b8700600152949656eb21f7'],
    '3d' => [0, '67bee4599a28e1cadc14ed9ea4adc7061e250b90'],
    base => [138, 'b9906b5233a80cab372c95ac4dd68b25bdca0646'],
    charts => [0, '3f3f14d69a509c3e8027bfb5d7ffca9b4f3ef003'],
    connectivity => [4, '8024ef3d7269665ba104f528e5e284df9d9d8ae9'],
    datavis3d => [0, '6ac6d23a8f558f36f1162b419858cc44dccd4d2b'],
    declarative => [30, 'b99568135aa60de96ca2e121dc2e8d83fb1ca886'],
    gamepad => [0, '44255e2ae53a14e9a3fb671da0782ec5d396220a'],
    graphicaleffects => [0, '895f9753940156dda05aa83d3c7655571514407e'],
    imageformats => [7, '63ec444cc7b30c45d4c8beb2c1071a1157d689eb'],
    location => [6, 'c576985da4e6a4a0b85d5229263777e7197494e0'],
    lottie => [0, '62f17bbc0ae8649178ac484afc434dbad16d6351'],
    multimedia => [2, '7514352532f41d9f0f8b8d722e360b1854442731'],
    networkauth => [0, 'ed2291d454fac207f6b1555d30b9227e51be611b'],
    purchasing => [0, '7f4ead6f3e6431acee63987a0a1753ff140ac2d2'],
    quick3d => [1, 'a0c37ca7615e95d69bcf6de8f19607bd46e8c37a'],
    quickcontrols => [0, '77fbfa8d313bbdb8fb762f15dd6173a067be55e3'],
    quickcontrols2 => [5, '1fc98160580fc7b791e20d34ba986c9992cae9c5'],
    quicktimeline => [0, '29394e35db43acb20e7b4d5e978a733f5b4232a6'],
    remoteobjects => [0, '18ef1cdce7bc4c93415f38f1c220ab697aa75908'],
    scxml => [0, '6074956c2089dd0507d2930c638fa8c930f4e21c'],
    sensors => [0, '7f8b55744f87155a4979dd8ba405bd7feec03042'],
    serialbus => [0, '5efce7d821bad2f5db95ff3ada5eeddccbb58920'],
    serialport => [0, 'fc0b6affe244e40366bd624d6e01c62712568eb8'],
    speech => [1, '9b3738febbc751820ede496e8d619c5be56548dc'],
    svg => [6, '080fed6443e9e7b2ad30e61f31163e9481dfad0f'],
    tools => [4, 'ba4c633c4a4731ead0c376b908bf5449796f7de1'],
    translations => [0, '40aabebd04a30ccef374bf20a7bfaa1d8d665b7f'],
    virtualkeyboard => [0, '80565aa7fc37ecdb1c08e585d4ae3060618e3338'],
    wayland => [60, '9c82b5461736f59a06923ab68c6f7584ecab4f77'],
    webchannel => [3, 'c78ad286a90e3d7986292b4a6036a9927bbc155f'],
    webglplugin => [0, '80257933d3bf3a026455d71106e6b3e70dead765'],
    websockets => [2, '2c2b7691ae231f43129d7f2b43984c30883ca4b1'],
    webview => [0, '3d9289d73c5c03ed5b2fe246589d0d81cfdaa22e'],
    x11extras => [0, '415ac0d58521be2bb00ef4cecdb16f0b9001e88c'],
    xmlpatterns => [0, 'eb59017f04b44667e0c6778aa3995f8e86c98e48'],
);
# $rev := git rev-list --count v5.15.2..$commit_on_kde_fork

# find templates; populate "pages" array
my @pages;
my $template_file_name = 'PKGBUILD.sh.ep';
my $top_level_dirs = $pkgbuilds_dir->list({dir => 1});
for my $top_level_dir (@$top_level_dirs) {
    next unless -d $top_level_dir;
    next unless $top_level_dir ne 'devel';

    my $default_package_name = $top_level_dir->basename;
    my ($qt_module, $qt_major_version);
    if ($default_package_name =~ qr/qt(5|6)-(.*)/) {
        $qt_major_version = $1;
        $qt_module        = $2;
    }

    my $kde_fork_revision;
    if ($qt_major_version && $qt_major_version eq '5' && $qt_module) {
        $kde_fork_revision = $kde_fork_revisions{$qt_module};
    }

    my $variant_dirs = $top_level_dir->list({dir => 1});
    for my $variant_dir (@$variant_dirs) {
        next unless -d $variant_dir;

        my $variant = $variant_dir->basename;
        my $template_file = $variant_dir->child($template_file_name);
        if (!-f $template_file) {
            # print warning; all additional Qt repos for mingw-w64 should be converted to use templates now
            $log->warn("No template $template_file_name present for Qt module $qt_module and variant $variant")
                if defined $qt_module && index($variant, 'mingw-w64') == 0 && $variant !~ qr/.*-test$/;
            next;
        }

        # determine files
        my $files = $variant_dir->list;
        my $patch_files = $files->grep(qr/.*\.patch/);
        my $qt_module_sha256_file_name = "qt$qt_module-sha256.txt";
        my $qt_module_sha256_file = defined $qt_module
            ? $variant_dir->child($qt_module_sha256_file_name)
            : undef;
        my $qt_module_sha256 = defined $qt_module_sha256_file && -f $qt_module_sha256_file
            ? Mojo::Util::trim($qt_module_sha256_file->slurp)
            : "$qt_module_sha256_file_name missing";

        # determine variant parts
        my $variant_prefix_part = $variant;
        my $variant_suffix_part = '';
        if ($variant) {
            for my $variant_suffixes (@variant_suffixes) {
                for my $variant_suffix (@$variant_suffixes) {
                    next unless $variant =~ qr/.*-$variant_suffix$/;
                    $variant_prefix_part = substr($variant, 0, length($variant) - length($variant_suffix) - 1);
                    $variant_suffix_part = $variant_suffix_part ? "$variant_suffix-$variant_suffix_part" : $variant_suffix;
                    last;
                }
            }
        }
        my $package_name_prefix = $variant_prefix_part ? "$variant_prefix_part-" : "";
        my $package_name_suffix = $variant_suffix_part ? "-$variant_suffix_part" : "";
        my $is_static_variant   = $variant_suffix_part =~ qr/static/;
        my $has_static_variant  = $is_static_variant || -d "$default_package_name/$variant-static";
        my $is_mingw            = $package_name_prefix eq 'mingw-w64-';
        my $package_name        = "$package_name_prefix$default_package_name$package_name_suffix";
        next if defined $filter_regex && $package_name !~ $filter_regex;

        push(@pages, {
                install_path => "$default_package_name/$variant/PKGBUILD",
                template_params => [
                template => "$default_package_name/$variant/PKGBUILD",
                stash_variables => {
                    variant => $variant,
                    variant_prefix_part => $variant_prefix_part,
                    variant_suffix_part => $variant_suffix_part,
                    default_package_name => $default_package_name,
                    package_name_prefix => $package_name_prefix,
                    package_name_suffix => $package_name_suffix,
                    package_name => $package_name,
                    files => $files,
                    patch_files => $patch_files,
                    qt_major_version => $qt_major_version,
                    qt_module => $qt_module,
                    qt_module_sha256 => $qt_module_sha256,
                    kde_fork_revision => $kde_fork_revision,
                    static_variant => $is_static_variant,
                    static_suffix => $is_static_variant ? '-static' : '',
                    static_deps => undef,
                    static_makedeps => undef,
                    is_mingw => $is_mingw,
                    library_extension => $is_static_variant ? 'a' : ($is_mingw ? 'dll.a' : 'so'),
                    install_prefix => $is_mingw ? '/usr/$_arch' : '/usr',
                    shared_config => !$is_static_variant,
                    static_config => $is_static_variant || !$has_static_variant,
                    no_libraries => 0,
                },
            ]
        });
    }
}

# render "pages"
for my $page (@pages) {
    # process template params
    my $template_params = $page->{template_params};
    my $template_source_path;
    my $template_target_path;
    my $template_stash_variables;
    if (defined $template_params) {
        my ($template_name, $template_args) = (@$template_params % 2 ? shift @$template_params : undef, {@$template_params});
        my $template_format = ($template_args->{format} //= 'sh');
        my $template_handler = $template_args->{handler} // 'ep';
        $template_name             //= $template_args->{template};
        $template_stash_variables    = delete $template_args->{stash_variables};
        $template_source_path        = "$template_name.$template_format.$template_handler";
        $template_target_path        = "$template_name.$template_format";
        $template_params             = $template_args;
        $template_params->{template} = $template_name;
    }

    # determine source path and target path
    my $source_path = $page->{source_path} // $template_source_path;
    if (!$template_params && !$source_path) {
        die 'page needs either template_params or source_path';
    }
    my $output_file = path($install_directory, $page->{install_path} // $template_target_path // $source_path);

    # ensure output directory exists
    $output_file->dirname->make_path unless -f $output_file;

    # skip unless the target is outdated
    # note: Can not skip templates that easy because that would require tracking includes.
    if (!defined $template_params && !is_outdated($source_path, $output_file)) {
        $log->info("Skipping '$source_path' -> '$output_file' (target up-to-date)");
        next;
    }

    # do a simple copy
    if (!defined $template_params) {
        $log->info("Copying '$source_path' -> '$output_file'");
        Mojo::File->new($source_path)->copy_to($output_file);
        next;
    }

    # render template
    $log->info("Rendering '$source_path' -> '$output_file'");
    my $controller = $mojolicious->build_controller;
    $controller->stash($template_stash_variables) if defined $template_stash_variables;
    my $output = $controller->render_to_string(%$template_params);
    $log->debug($output);
    $output_file->spew($output, 'UTF-8');
}
