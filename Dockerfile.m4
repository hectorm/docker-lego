m4_changequote([[, ]])

m4_ifdef([[CROSS_QEMU]], [[
##################################################
## "qemu-user-static" stage
##################################################

FROM ubuntu:18.04 AS qemu-user-static
RUN export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends qemu-user-static
]])

##################################################
## "build-lego" stage
##################################################

FROM golang:1-stretch AS build-lego
m4_ifdef([[CROSS_QEMU]], [[COPY --from=qemu-user-static CROSS_QEMU CROSS_QEMU]])

# Install system packages
RUN export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		file

# Build Dep
RUN go get -v -d github.com/golang/dep \
	&& cd "${GOPATH}/src/github.com/golang/dep" \
	&& git checkout "$(git describe --abbrev=0 --tags)"
RUN cd "${GOPATH}/src/github.com/golang/dep" \
	&& go build -o ./cmd/dep/dep ./cmd/dep/ \
	&& mv ./cmd/dep/dep /usr/bin/dep

# Copy patches
COPY patches/ /tmp/patches/

# Build lego
ARG LEGO_TREEISH=v2.4.0
RUN go get -v -d github.com/go-acme/lego/cmd/lego \
	&& cd "${GOPATH}/src/github.com/go-acme/lego" \
	&& git checkout "${LEGO_TREEISH}" \
	&& dep ensure
RUN cd "${GOPATH}/src/github.com/go-acme/lego" \
	&& for f in /tmp/patches/lego-*.patch; do [ -e "$f" ] || continue; git apply -v "$f"; done \
	&& export GOOS=m4_ifdef([[CROSS_GOOS]], [[CROSS_GOOS]]) \
	&& export GOARCH=m4_ifdef([[CROSS_GOARCH]], [[CROSS_GOARCH]]) \
	&& export GOARM=m4_ifdef([[CROSS_GOARM]], [[CROSS_GOARM]]) \
	&& export LDFLAGS="-X main.version=${LEGO_TREEISH}" \
	&& go build -o ./dist/lego -ldflags "${LDFLAGS}" ./cmd/lego/main.go \
	&& mv ./dist/lego /usr/bin/lego \
	&& file /usr/bin/lego && /usr/bin/lego --version

##################################################
## "lego" stage
##################################################

m4_ifdef([[CROSS_ARCH]], [[FROM CROSS_ARCH/ubuntu:18.04]], [[FROM ubuntu:18.04]]) AS lego
m4_ifdef([[CROSS_QEMU]], [[COPY --from=qemu-user-static CROSS_QEMU CROSS_QEMU]])

# Environment
ENV LEGOPATH=/var/lib/lego

# Install system packages
RUN export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		ca-certificates \
		libcap2-bin \
	&& rm -rf /var/lib/apt/lists/*

# Create users and groups
ARG LEGO_USER_UID=1000
ARG LEGO_USER_GID=1000
RUN groupadd \
		--gid "${LEGO_USER_GID}" \
		lego
RUN useradd \
		--uid "${LEGO_USER_UID}" \
		--gid "${LEGO_USER_GID}" \
		--shell "$(which bash)" \
		--home-dir /home/lego/ \
		--create-home \
		lego

# Copy lego build
COPY --from=build-lego --chown=root:root /usr/bin/lego /usr/bin/lego

# Add capabilities to the lego binary
RUN setcap cap_net_bind_service=+ep /usr/bin/lego

# Create $LEGOPATH directory (lego will use this directory to store data)
RUN mkdir -p "${LEGOPATH}" && chown lego:lego "${LEGOPATH}" && chmod 700 "${LEGOPATH}"

# Drop root privileges
USER lego:lego

ENTRYPOINT ["/usr/bin/lego"]
CMD ["--help"]
