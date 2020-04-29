# ISC License
#
# Copyright 2020; Luiz Berti <https://berti.me>
#
# Permission to use, copy, modify, and/or distribute this software
# for any purpose with or without fee is hereby granted, provided
# that the above copyright notice and this permission notice
# appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
# WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
# AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
# CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
# LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
# NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
# CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

ARG LANG=C.UTF-8
ARG LC_ALL=C.UTF-8
ARG GLIBC_VERSION=2.31
ARG GLIBC_SIGKEY=BC7C7372637EC10C57D7AA6579C43DFBF1CF2187


FROM ubuntu:20.04 AS builder-glibc
WORKDIR /usr/src/glibc

ARG LANG
ARG LC_ALL
ARG GLIBC_VERSION
ARG GLIBC_SIGKEY

RUN apt update && apt install -y --no-install-recommends --no-upgrade \
    gpg gpg-agent dirmngr build-essential bison gawk python3

ADD https://ftp.gnu.org/gnu/glibc/glibc-$GLIBC_VERSION.tar.xz     glibc.tar.xz
ADD https://ftp.gnu.org/gnu/glibc/glibc-$GLIBC_VERSION.tar.xz.sig glibc.sig
RUN gpg --keyserver hkps://hkps.pool.sks-keyservers.net --receive-keys $GLIBC_SIGKEY
RUN gpg --verify glibc.sig glibc.tar.xz
RUN tar --extract --xz --strip-components=1 --file=glibc.tar.xz && rm glibc.tar.xz

# BUILD FINAL ARTIFACT @ /glibc-bin.tar.xz
WORKDIR /root
RUN mkdir -p /usr/glibc/lib
RUN /usr/src/glibc/configure \
    --prefix=/usr/glibc \
    --libdir=/usr/glibc/lib \
    --libexecdir=/usr/glibc/lib \
    --enable-multi-arch \
    --enable-stack-protector=strong \
    --enable-cet
RUN make PARALLELMFLAGS="-j $(nproc)" && make install
RUN tar --create --xz --dereference --hard-dereference --file=/glibc-bin.tar.xz /usr/glibc/*


FROM alpine:3.11 AS builder-apk
RUN apk add alpine-sdk
RUN adduser -D builder -G abuild
RUN echo 'builder ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
RUN mkdir /packages && chown builder:abuild /packages /opt

USER builder
RUN mkdir -p /home/builder/glibc/src
WORKDIR /home/builder/glibc/src

# CONFIGURE APK BUILD ENVIRONMENT
COPY APKBUILD .
COPY --from=builder-glibc /glibc-bin.tar.xz .
RUN echo /usr/local/lib >  ld.so.conf && \
    echo /usr/glibc/lib >> ld.so.conf && \
    echo /usr/lib       >> ld.so.conf && \
    echo /lib           >> ld.so.conf
RUN echo '#!/bin/sh'               >  glibc-bin.trigger && \
    echo  /usr/glibc/sbin/ldconfig >> glibc-bin.trigger && \
    chmod 775 glibc-bin.trigger
RUN abuild checksum

# BUILD PACKAGE (NOTE signed with build-time ephemeral key)
ARG GLIBC_VERSION
RUN abuild-keygen -ain && abuild -r -P /packages

# TODO check if we need all `*.apk` files or just `glibc-bin-*.apk` or naked `glibc.apk`
RUN cp /packages/glibc/x86_64/glibc-$GLIBC_VERSION-r0.apk /opt/glibc.apk
RUN cp /packages/glibc/x86_64/glibc-bin-*.apk             /opt/glibc-bin.apk
RUN cp /packages/glibc/x86_64/glibc-i18n-*.apk            /opt/glibc-i18n.apk


FROM alpine:3.11 AS fat
COPY --from=builder-apk /opt/glibc*.apk /
ARG LANG
ARG LC_ALL

# TODO can we parametrize UTF-8 with build ARG? can we run `localedef` in a previous build step?
RUN apk add --allow-untrusted --no-cache /glibc.apk /glibc-bin.apk /glibc-i18n.apk
RUN /usr/glibc/bin/localedef --force --inputfile POSIX --charmap UTF-8 $LC_ALL || true
RUN rm /*.apk


FROM fat AS testing
# SETUP MINICONDA
ARG PYTHONDONTWRITEBYTECODE=1
ARG PATH=/opt/conda/bin:$PATH
ADD http://repo.continuum.io/miniconda/Miniconda3-4.7.12.1-Linux-x86_64.sh miniconda.sh
RUN bash miniconda.sh -f -b -p /opt/conda && rm miniconda.sh
RUN conda update --all --yes
RUN conda config --set auto_update_conda False
RUN conda clean --all --force-pkgs-dirs --yes
RUN conda config --add channels conda-forge
RUN conda install -y numpy
# THE ACTUAL TEST
RUN python -c 'import numpy as np; print(np.array([0, 1, 2]).tolist())'


FROM scratch AS final
COPY --from=fat / /
ARG LANG
ARG LC_ALL
ENV LANG=$LANG LC_ALL=$LC_ALL

