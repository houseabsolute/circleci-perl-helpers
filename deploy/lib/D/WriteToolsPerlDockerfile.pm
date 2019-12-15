package D::WriteToolsPerlDockerfile;

use v5.30.1;
use strict;
use warnings;
use feature 'postderef', 'signatures';
use warnings 'FATAL' => 'all';
use autodie qw( :all );
use namespace::autoclean;

use Moose;
## no critic (TestingAndDebugging::ProhibitNoWarnings)
no warnings 'experimental::postderef', 'experimental::signatures';
## use critic

with 'R::DockerfileWriter', 'R::PerlReleaseFetcher', 'R::Tagger';

has '+perl' => (
    required => 0,
    lazy     => 1,
    default  => sub ($self) { $self->_latest_stable_perl->version },
);

sub run ($self) {
    $self->_write_dockerfile;
    say $self->_base_image_tag
        or die $!;
    return 0;
}

## no critic (Subroutines::ProhibitUnusedPrivateSubroutines)
sub _content ($self) {
    return sprintf( <<'EOF', $self->perl );
FROM ubuntu:bionic

RUN apt-get --yes update && \
    apt-get --yes upgrade && \
    apt-get --yes --no-install-recommends install \
        # For spelling tests
        aspell \
        aspell-en \
        ca-certificates \
        # Note that having curl over wget is important. When wget is installed
        # cpm will use that and then get weird 404 errors when making requests
        # to various metacpan URIs.
        curl \
        gcc \
        git \
        g++ \
        # Just added to make shelling in more pleasant.
        less \
        libc6-dev \
        # For XML-Parser which is a transitive dep of TAP::Harness::JUnit.
        libexpat-dev \
        # Same as less.
        libreadline7 \
        libssl1.1 \
        libssl-dev \
        make \
        patch \
        perl \
        # Needed in Azure CI where we don't run as root.
        # This is handy for debugging path issues.
        tree \
        zlib1g \
        zlib1g-dev

RUN mkdir ~/bin && \
    curl -fsSL --compressed https://git.io/cpm > /usr/local/bin/cpm && \
    chmod 0755 /usr/local/bin/cpm

RUN curl -L https://install.perlbrew.pl | sh && \
        mv /root/perl5 /usr/local/perl5

ENV PERLBREW_ROOT=/usr/local/perl5/perlbrew

ENV PATH=/usr/local/perl5/perlbrew/bin:$PATH

RUN perlbrew install --verbose --notest --noman -j $(nproc) --as tools-perl %s && \
    perlbrew clean

# We do this separately so we don't have to re-install everything when the
# tools code changes but the prereqs don't.
COPY ./tools/cpanfile /usr/local/ci-perl-helpers-tools/cpanfile

RUN perlbrew exec --with tools-perl \
        /usr/local/bin/cpm install \
            --global \
            --show-build-log-on-failure \
            --verbose \
            --workers 16 \
            --feature docker \
            --feature tools-perl \
            --cpanfile /usr/local/ci-perl-helpers-tools/cpanfile \
    && rm -fr /root/.perl-cpm

LABEL maintainer="Dave Rolsky <autarch@urth.org>"
EOF
}
## use critic

__PACKAGE__->meta->make_immutable;

1;
