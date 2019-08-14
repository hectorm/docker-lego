m4_changequote([[, ]])

##################################################
## "build-lego" stage
##################################################

FROM docker.io/golang:1-stretch AS build-lego
m4_ifdef([[CROSS_QEMU]], [[COPY --from=docker.io/hectormolinero/qemu-user-static:latest CROSS_QEMU CROSS_QEMU]])

# Environment
ENV GO111MODULE=on
ENV CGO_ENABLED=0
ENV GOOS=m4_ifdef([[CROSS_GOOS]], [[CROSS_GOOS]])
ENV GOARCH=m4_ifdef([[CROSS_GOARCH]], [[CROSS_GOARCH]])
ENV GOARM=m4_ifdef([[CROSS_GOARM]], [[CROSS_GOARM]])

# Install system packages
RUN export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		file \
		tzdata \
	&& rm -rf /var/lib/apt/lists/*

# Copy patches
COPY patches/ /tmp/patches/

# Build lego
ARG LEGO_TREEISH=v3.0.1
ARG LEGO_REMOTE=https://github.com/go-acme/lego.git
WORKDIR /go/src/lego/
RUN git clone "${LEGO_REMOTE}" ./
RUN git checkout "${LEGO_TREEISH}"
RUN git submodule update --init --recursive
RUN for f in /tmp/patches/lego-*.patch; do [ -e "$f" ] || continue; git apply -v "$f"; done
RUN go build -o ./dist/lego -ldflags "-s -w -X main.version=${LEGO_TREEISH}" ./cmd/lego/main.go
RUN mv ./dist/lego /usr/bin/lego
RUN file /usr/bin/lego
RUN /usr/bin/lego --version

##################################################
## "lego" stage
##################################################

m4_ifdef([[CROSS_ARCH]], [[FROM docker.io/CROSS_ARCH/ubuntu:18.04]], [[FROM docker.io/ubuntu:18.04]]) AS lego
m4_ifdef([[CROSS_QEMU]], [[COPY --from=docker.io/hectormolinero/qemu-user-static:latest CROSS_QEMU CROSS_QEMU]])

# Environment
ENV LEGOPATH=/var/lib/lego

# Install system packages
RUN export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		ca-certificates \
		libcap2-bin \
		tzdata \
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
		--shell "$(command -v bash)" \
		--home-dir /home/lego/ \
		--create-home \
		lego

# Copy lego build
COPY --from=build-lego --chown=root:root /usr/bin/lego /usr/bin/lego

# Add capabilities to the lego binary (this allows lego to bind to privileged ports
# without being root, but creates another layer that increases the image size)
RUN setcap cap_net_bind_service=+ep /usr/bin/lego

# Create $LEGOPATH directory (lego will use this directory to store data)
RUN mkdir -p "${LEGOPATH}" && chown lego:lego "${LEGOPATH}" && chmod 700 "${LEGOPATH}"

# Drop root privileges
USER lego:lego

ENTRYPOINT ["/usr/bin/lego"]
CMD ["--help"]
