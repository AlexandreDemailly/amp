
.PHONY: all clean build build-cli build-server build-agent build-log-worker install install-server install-cli install-agent install-log-worker fmt simplify check version build-image run
.PHONY: test

SHELL := /bin/bash
BASEDIR := $(shell echo $${PWD})

# build variables (provided to binaries by linker LDFLAGS below)
VERSION := 1.0.0
BUILD := $(shell git rev-parse HEAD | cut -c1-8)

LDFLAGS=-ldflags "-X=main.Version=$(VERSION) -X=main.Build=$(BUILD)"

# ignore vendor directory for go files
SRC := $(shell find . -type f -name '*.go' -not -path './vendor/*' -not -path './.git/*')

# for walking directory tree (like for proto rule)
EXCLUDE_FILES_FILTER := -not -path './vendor/*' -not -path './.git/*' -not -path './.glide/*'
EXCLUDE_DIRS_FILTER := $(EXCLUDE_FILES_FILTER) -not -path '.' -not -path './vendor' -not -path './.git' -not -path './.glide'

DIRS = $(shell find . -type d $(EXCLUDE_DIRS_FILTER))

# generated file dependencies for proto rule
PROTOFILES = $(shell find . -type f -name '*.proto' $(EXCLUDE_DIRS_FILTER))

# generated files that can be cleaned
GENERATED := $(shell find . -type f -name '*.pb.go' $(EXCLUDE_FILES_FILTER))

# ignore generated files when formatting/linting/vetting
CHECKSRC := $(shell find . -type f -name '*.go' -not -name '*.pb.go' $(EXCLUDE_FILES_FILTER))

OWNER := appcelerator
REPO := github.com/$(OWNER)/amp

CMDDIR := cmd
CLI := amp
SERVER := amplifier
AGENT := amp-agent
LOGWORKER := amp-log-worker

TAG := latest
IMAGE := $(OWNER)/amp:$(TAG)

# tools
# need UID:GID because files created by containerized tools when mounting
# cwd are set to root:root
UG := $(shell echo "$$(id -u $${USER}):$$(id -g $${USER})")

DOCKER_RUN := docker run -t --rm -u $(UG)

GOTOOLS := appcelerator/gotools2
GOOS := $(shell uname | tr [:upper:] [:lower:])
GOARCH := amd64
GO := $(DOCKER_RUN) --name go -v $${HOME}/.ssh:/root/.ssh -v $${PWD}:/go/src/$(REPO) -w /go/src/$(REPO) -e GOOS=$(GOOS) -e GOARCH=$(GOARCH) $(GOTOOLS) go
GOTEST := $(DOCKER_RUN) --name go -v $${HOME}/.ssh:/root/.ssh -v $${GOPATH}/bin:/go/bin -v $${PWD}:/go/src/$(REPO) -w /go/src/$(REPO) $(GOTOOLS) go test -v

GLIDE_DIRS := $${HOME}/.glide $${PWD}/.glide vendor
GLIDE := $(DOCKER_RUN) -u $(UG) -v $${HOME}/.ssh:/root/.ssh -v $${HOME}/.glide:/root/.glide -v $${PWD}:/go/src/$(REPO) -w /go/src/$(REPO) $(GOTOOLS) glide $${GLIDE_OPTS}
GLIDE_INSTALL := $(GLIDE) install
GLIDE_UPDATE := $(GLIDE) update

TEST_PACKAGES = $(REPO)/data/storage/etcd $(REPO)/data/influx $(REPO)/api/rpc/stack
# $(REPO)/api/rpc/build @go test -v $(REPO)/api/rpc/project

all: version check build

arch:
	@echo $(GOOS)

version:
	@echo "version: $(VERSION) (build: $(BUILD))"

clean:
	@rm -rf $(GENERATED)
	@rm -f $$(which $(CLI)) ./$(CLI)
	@rm -f $$(which $(SERVER)) ./$(SERVER)
	@rm -f coverage.out coverage-all.out

install-deps:
	@$(GLIDE_INSTALL)

update-deps:
	@$(GLIDE_UPDATE)

install: install-cli install-server install-agent install-log-worker

install-cli: proto
	@go install $(LDFLAGS) $(REPO)/$(CMDDIR)/$(CLI)

install-server: proto
	@go install $(LDFLAGS) $(REPO)/$(CMDDIR)/$(SERVER)

install-agent: proto
	@go install $(LDFLAGS) $(REPO)/$(CMDDIR)/$(AGENT)

install-log-worker: proto
	@go install $(LDFLAGS) $(REPO)/$(CMDDIR)/$(LOGWORKER)

build: build-cli build-server build-agent build-log-worker

build-cli: proto
	@hack/build $(CLI)

build-server: proto
	@hack/build $(SERVER)

build-agent: proto
	@hack/build $(AGENT)

build-log-worker: proto
	@hack/build $(LOGWORKER)

build-server-image:
	@docker build -t appcelerator/$(SERVER):$(TAG) .

proto: $(PROTOFILES)
	@go run hack/proto.go

# used to install when you're already inside a container
install-host: proto-host
	@go install $(LDFLAGS) $(REPO)/$(CMDDIR)/$(CLI)
	@go install $(LDFLAGS) $(REPO)/$(CMDDIR)/$(SERVER)
	@go install $(LDFLAGS) $(REPO)/$(CMDDIR)/$(AGENT)
	@go install $(LDFLAGS) $(REPO)/$(CMDDIR)/$(LOGWORKER)

# used to run protoc when you're already inside a container
proto-host: $(PROTOFILES)
	@go run hack/proto.go -protoc

# format and simplify if possible (https://golang.org/cmd/gofmt/#hdr-The_simplify_command)
fmt:
	@gofmt -s -l -w $(CHECKSRC)

check:
	@test -z $(shell gofmt -l ${CHECKSRC} | tee /dev/stderr) || echo "[WARN] Fix formatting issues with 'make fmt'"
	@$(DOCKER_RUN) -v $${PWD}:/go/src/$(REPO) -w /go/src/$(REPO) $(GOTOOLS) bash -c 'for p in $$(go list ./... | grep -v /vendor/); do golint $${p} | sed "/pb\.go/d"; done'
	@go tool vet ${CHECKSRC}

build-image:
	@docker build -t $(IMAGE) .

run: build-image
	@CID=$(shell docker run --net=host -d --name $(SERVER) $(IMAGE)) && echo $${CID}

test:
	@go test -v ./api/rpc/tests
	$(foreach pkg,$(TEST_PACKAGES),\
		go test -v $(pkg);)

cover:
	echo "mode: count" > coverage-all.out
	$(foreach pkg,$(TEST_PACKAGES),\
		go test -coverprofile=coverage.out -covermode=count $(pkg);\
		tail -n +2 coverage.out >> coverage-all.out;)
	go tool cover -html=coverage-all.out

