package R::HelperScript;

use strict;
use warnings;

use CPAN::Meta;
use Config qw( %Config );
use Data::Dumper::Concise qw( Dumper );
use Devel::Confess;
use File::Which qw( which );
use File::pushd qw( pushd );
use FindBin qw( $Bin );
use IPC::Run3 qw( run3 );
use Module::CPANfile;
use Path::Tiny qw( path );
use Path::Tiny::Rule;
use Specio::Declare qw( enum );
use Specio::Library::Builtins;
use Specio::Library::Path::Tiny;

# For things using autodie qw( :all )
use IPC::System::Simple;

use Moo::Role;

has checkout_dir => (
    is      => 'ro',
    isa     => t('Dir'),
    lazy    => 1,
    default => sub { path( $ENV{CI_SOURCE_DIRECTORY} )->absolute },
);

has workspace_root => (
    is      => 'ro',
    isa     => t('Dir'),
    lazy    => 1,
    default => sub { path( $ENV{CI_WORKSPACE_DIRECTORY} )->absolute },
);

has cache_dir => (
    is      => 'ro',
    isa     => t('Dir'),
    lazy    => 1,
    default => sub {
        my $d = $_[0]->workspace_root->child('cache');
        $d->mkpath( 0, 0755 );
        $d;
    },
);

has artifact_dir => (
    is      => 'ro',
    isa     => t('Dir'),
    lazy    => 1,
    default => sub {
        my $d = path( $ENV{CI_ARTIFACT_STAGING_DIRECTORY} )->absolute;
        $d->mkpath( 0, 0755 );
        $d;
    },
);

has extracted_dist_dir => (
    is      => 'ro',
    isa     => t('Dir'),
    lazy    => 1,
    default => sub {
        my $d = $_[0]->workspace_root->child('extracted-dist');
        $d->mkpath( 0, 0755 );
        $d;
    },
);

has tools_dir => (
    is      => 'ro',
    isa     => t('Dir'),
    lazy    => 1,
    default => sub {
        $^O eq 'linux'
            ? path(qw( /usr local ci-perl-helpers-tools ))->absolute
            : $_[0]->workspace_root->child('ci-perl-helpers-tools');
    },
);

has brew_dir => (
    is      => 'ro',
    isa     => t('Dir'),
    lazy    => 1,
    default => sub {
        $^O eq 'linux' ? path(qw( /usr local perl5 perlbrew ))->absolute
            : $^O eq 'darwin'
            ? $_[0]->workspace_root->child(qw( perl5 perlbrew ))
            : path('C:\berrybrew');
    },
);

has is_dzil => (
    is      => 'ro',
    isa     => t('Bool'),
    lazy    => 1,
    default => sub { $_[0]->checkout_dir->child('dist.ini')->is_file },
);

has is_minilla => (
    is      => 'ro',
    isa     => t('Bool'),
    lazy    => 1,
    builder => '_build_is_minilla',
);

sub _build_is_minilla {
    my $self = shift;

    return 1 if $self->checkout_dir->child('minil.toml')->exists;

    return 0 unless $self->has_build_pl;

    for my $line ( $self->build_pl->lines ) {
        return 1 if $line =~ /GENERATED BY MINILLA/;
    }

    return 0;
}

has is_module_install => (
    is      => 'ro',
    isa     => t('Bool'),
    lazy    => 1,
    builder => '_build_is_module_install',
);

sub _build_is_module_install {
    my $self = shift;

    return 0 unless $self->has_makefile_pl;

    my $content = $self->makefile_pl->slurp_utf8;
    return 1 if $content =~ /Module::Install/;

    return 0;
}

has build_pl => (
    is      => 'ro',
    isa     => t('Path'),
    lazy    => 1,
    default => sub { $_[0]->checkout_dir->child('Build.PL') },
);

has has_build_pl => (
    is      => 'ro',
    isa     => t('Bool'),
    lazy    => 1,
    default => sub { $_[0]->build_pl->is_file },
);

has makefile_pl => (
    is      => 'ro',
    isa     => t('Path'),
    lazy    => 1,
    default => sub { $_[0]->checkout_dir->child('Makefile.PL') },
);

has has_makefile_pl => (
    is      => 'ro',
    isa     => t('Bool'),
    lazy    => 1,
    default => sub { $_[0]->makefile_pl->is_file },
);

has tools_perl => (
    is      => 'ro',
    isa     => t('Str'),
    default => sub { $^O eq 'MSWin32' ? '5.30.0_64' : 'tools-perl' },
);

has runtime_perl => (
    is      => 'ro',
    isa     => t('Str'),
    default => 'runtime-perl',
);

has runtime_is_5_8 => (
    is      => 'ro',
    isa     => t('Bool'),
    lazy    => 1,
    default => sub { $_[0]->runtime_perl_version->[0] == 8 },
);

has runtime_perl_version => (
    is      => 'ro',
    isa     => t( 'ArrayRef', of => t('Int') ),
    lazy    => 1,
    builder => '_build_runtime_perl_version',
);

sub _build_runtime_perl_version {
    my $self = shift;

    my $version = join q{}, $self->_run3(
        [
            $self->_brewed_perl( $self->runtime_perl ),
            'perl',
            '-e',
            'print $]',
        ],
    );

    my ( $min, $patch ) = $version =~ /5\.(\d\d\d)(\d\d\d)/;
    $min   += 0;
    $patch += 0;

    return [ $min, $patch ];
}

has make => (
    is      => 'ro',
    isa     => t('Str'),
    default => sub { $^O eq 'MSWin32' ? 'gmake' : 'make' },
);

has allow_test_failures => (
    is      => 'ro',
    isa     => t('Bool'),
    default => $ENV{CIPH_ALLOW_FAILURE},
);

has debug => (
    is      => 'ro',
    isa     => t('Bool'),
    default => $ENV{CIPH_DEBUG},
);

## no critic (Subroutines::ProhibitUnusedPrivateSubroutines )
sub _pushd {
    my $self = shift;
    my $dir  = shift;

    $self->_debug("pushd $dir");
    return pushd($dir);
}

sub _debug_step {
    my $self = shift;
    my $step = ref $self;

    $self->_debug("Running $step step");

    return undef;
}

sub _debug {
    my $self = shift;

    return unless $self->debug;

    print ">>> CIPH: @_\n" or die $!;

    return undef;
}

sub _run3 {
    my $self       = shift;
    my $cmd        = shift;
    my $always_tee = shift;

    my ( @stdout, $stderr );
    $self->_debug("Running [@{$cmd}] from $0");
    run3(
        $cmd,
        \undef,
        $self->_tee( \@stdout, $always_tee ),
        \$stderr,
    );

    if ( $? || $stderr ) {
        my $msg
            = "Error running [@{$cmd}] - exit status was "
            . ( $? << 8 ) . "\n";
        if ( defined $stderr && length $stderr ) {
            $msg .= "Stderr was:\n$stderr\n";
        }
        die $msg;
    }

    return @stdout;
}

sub _tee {
    my $self       = shift;
    my $out        = shift;
    my $always_tee = shift;

    return $out unless $always_tee || $self->debug;

    return sub {
        my $line = shift;
        print $line or die $!;
        push @{$out}, $line;
    };
}

has local_lib_root => (
    is      => 'ro',
    isa     => t('Path'),
    lazy    => 1,
    default => sub { $_[0]->workspace_root->child('local-lib') },
);

sub _with_brewed_perl_perl5lib {
    my $self = shift;
    my $perl = shift;
    my $sub  = shift;

    my @preserve;
    if ( $ENV{PATH} ) {
        @preserve = grep { !/local-lib/ } split /:/, $ENV{PATH};
    }
    my $bin_path = $self->local_lib_root->child( $perl, 'bin' );

    # We need to set the path if anything we run tries to execute another
    # script, like how tidyall tests run perlcritic.
    local $ENV{PATH} = join q{:}, $bin_path, @preserve;
    local $ENV{PERL5LIB}
        = $self->local_lib_root->child( $perl, qw( lib perl5 ) );

    return $sub->();
}

sub _brewed_perl {
    my $self = shift;
    my $perl = shift;

    my $brew = $^O eq 'MSWin32' ? 'berrybrew' : 'perlbrew';

    return ( $brew, 'exec', '--with', $perl );
}

sub _perl_local_script {
    my $self   = shift;
    my $perl   = shift;
    my $script = shift;

    # If we installed a newer version after a docker image was built it will
    # be in the local-lib tree.
    my @paths = $self->local_lib_root->child( $perl, 'bin', $script );
    if ( $^O eq 'MSWin32' ) {
        push @paths, (
            $self->brew_dir->child( $perl, 'perl', 'bin', $script ),
            $self->brew_dir->child( $perl, 'perl', 'site', 'bin', $script ),
        );
    }
    else {
        push @paths, $self->brew_dir->child( 'perls', $perl, 'bin', $script );
    }

    for my $path (@paths) {
        return $path if $path->is_file;
    }

    die "Could not find $script at any of: [@paths]";
}

sub _system {
    my $self = shift;
    my @cmd  = @_;

    return $self->_maybe_check_system( 1, @cmd );
}

sub _system_no_die {
    my $self = shift;
    my @cmd  = @_;

    return $self->_maybe_check_system( 0, @cmd );
}

sub _maybe_check_system {
    my $self  = shift;
    my $check = shift;
    my @cmd   = @_;

    $self->_debug("Running [@cmd] from $0");

    # no idea why this policy is complaining
    #
    ## no critic (InputOutput::RequireCheckedSyscalls)
    my $exit = system(@cmd);
    if ($check) {
        die "Could not run [@cmd]: $!"
            if $exit;
    }

    return $exit;
}

has cpan_install_bin => (
    is      => 'ro',
    isa     => t('File'),
    default => sub { path( $Bin, 'cpan-install.pl' ) },
);

sub cpan_install {
    my $self = shift;
    my $perl = shift;
    my @args = @_;

    die 'No additional arguments passed to the cpan_install method'
        unless @args;

    # We execute the cpan-install.pl script with our tools-perl, but we pass
    # `--perl $perl` to the cpan-install.pl script, which will in turn invoke
    # cpm with the perl we give it.
    $self->_with_brewed_perl_perl5lib(
        $self->tools_perl,
        sub {
            $self->_system(
                $self->_brewed_perl( $self->tools_perl ),
                'perl',
                $self->cpan_install_bin,
                '--perl', $perl,
                @args,
            );
        },
    );

    return undef;
}

sub _perl_v_to {
    my $self = shift;
    my $perl = shift;
    my $file = shift;

    my $pb = join q{ }, $self->_brewed_perl($perl);
    my $v  = $pb . ' perl -V';
    print "$perl is:\n" or die $!;
    $self->_system($v);
    print "\n\n" or die $!;

    # We're intentionally passing a single string so this goes through the
    # shell to do the redirect.
    $self->_system( $v . ' > ' . $file );
}

has test_paths => (
    is      => 'ro',
    isa     => t( 'ArrayRef', of => t('Path') ),
    lazy    => 1,
    builder => '_build_test_paths',
);

has coverage_partition => (
    is      => 'ro',
    isa     => t('Int'),
    lazy    => 1,
    default => sub { $ENV{CIPH_COVERAGE_PARTITION} || 0 },
);

has total_coverage_partitions => (
    is      => 'ro',
    isa     => t('Int'),
    lazy    => 1,
    default => sub { $ENV{CIPH_TOTAL_COVERAGE_PARTITIONS} || 0 },
);

has test_xt => (
    is      => 'ro',
    isa     => t('Bool'),
    default => $ENV{CIPH_TEST_XT},
);

sub _coverage_options {
    return qw( clover codecov coveralls html kritika sonarqube );
}

has coverage => (
    is      => 'ro',
    isa     => enum( values => [ q{}, __PACKAGE__->_coverage_options ] ),
    default => sub { $ENV{CIPH_COVERAGE} || q{} },
);

sub _build_test_paths {
    my $self = shift;

    return $self->_partition_tests
        ? $self->_this_coverage_partition
        : $self->_test_dirs;
}

sub _partition_tests {
    my $self = shift;
    return $self->coverage_partition && $self->total_coverage_partitions;
}

sub _this_coverage_partition {
    my $self = shift;

    my @dirs = $self->extracted_dist_dir->child('t');
    push @dirs, $self->extracted_dist_dir->child('xt')
        if $self->test_xt;

    # These are returned already sorted.
    my @files = Path::Tiny::Rule->new->file->name(qr/\.t$/)->all(@dirs);

    my $partition_size
        = int( ( scalar @files + $self->total_coverage_partitions - 1 )
        / $self->total_coverage_partitions );
    my $start = ( $self->coverage_partition - 1 ) * $partition_size;
    my $end   = $start + $partition_size;
    $end = $#files
        if $end > $#files;

    $self->_debug(
        sprintf(
            'Partitioning test files into %d groups of %d each and running group #%d',
            $self->total_coverage_partitions, $partition_size,
            $self->coverage_partition,
        ),
    );

    return [ @files[ $start .. $end ] ];
}

sub _test_dirs {
    my $self = shift;

    my %test_dirs = ( t => $self->extracted_dist_dir->child('t') );
    if ( $self->test_xt ) {
        my $xt = $self->extracted_dist_dir->child('xt');
        $test_dirs{xt} = $xt
            if $xt->is_dir;
    }

    # When running coverage testing we need to pass an absolute path to prove
    # because of https://github.com/pjcj/Devel--Cover/issues/247.
    return [ values %test_dirs ] if $self->coverage;

    # But absolute paths cause issues on Windows, so by default we won't use
    # them.
    return [ map { path($_) } keys %test_dirs ];
}

sub _load_cpan_meta_in {
    my $self = shift;
    my $dir  = shift;
    my $name = shift || 'META';

    for my $file (
        map { $dir->child($_) }
        map { "$name" . $_ } qw( .json .yml )
    ) {
        next unless $file->is_file;
        return CPAN::Meta->load_file($file);
    }

    return undef;
}

sub _write_cpanfile_from_meta {
    my $self     = shift;
    my $cpanfile = shift;
    my $meta     = shift;

    $cpanfile->spew(
        Module::CPANfile->from_prereqs( $meta->prereqs )->to_string );

    return 1;
}

before run => sub {
    my $self = shift;

    return unless $self->test_xt;
    ## no critic (Variables::RequireLocalizedPunctuationVars)
    $ENV{AUTOMATED_TESTING} = 1;
    $ENV{AUTHOR_TESTING}    = 1;
    $ENV{EXTENDED_TESTING}  = 1;
    $ENV{RELEASE_TESTING}   = 1;

    return;
};

# When running in bash under Windows, some programs don't do well when dealing
# with Windows paths, notably tar, so we need to translate them to Posix
# paths.
sub _posix_path {
    shift;
    my $path = path(shift)->absolute;
    $path =~ s{^([A-Z]):}{'/' . lc $1}e;
    $path =~ s{\\}{/}g;
    return path($path);
}

sub _show_env {
    my $self = shift;

    print "\$^O = $^O\n" or die $!;
    print "Env:\n" . Dumper( \%ENV ) or die $!;
    print 'Cwd = ', path(q{.})->realpath . "\n" or die $!;
    if ( my $tree = which('tree') ) {
        $self->_system( $tree, q{.} );
    }
    else {
        $self->_system(qw( ls -l . ));
    }
}

1;
