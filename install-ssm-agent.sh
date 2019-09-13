#!/usr/bin/env bash
# vim: et sr sw=4 ts=4 smartindent:
#
# 00030-amazon-ssm-agent.sh
#
# — pulls golang:1.6 image
# — checks out latest tag
# — builds amazon-ssm-agent
# — moves binaries into /home/core/bin/ssm/
export WERK_DIR="/home/core/ssm" ;
export BIN_DIR="/home/core/bin/ssm" ;
export CONFIG_DIR="/etc/amazon/ssm" ;
export DOCKER_BUILD_BOX="ssm-build" ;
export DOCKER_GOLANG_TAG="golang:1.13.0" ;
export DOCKER_WERKSPACE="/workspace/src/github.com/aws/amazon-ssm-agent" ;

ping -c 5 github.com ;

git clone https://github.com/aws/amazon-ssm-agent.git "${WERK_DIR}" ;

cd "${WERK_DIR}" || exit;

git checkout "$(git describe --abbrev=0 --tags)" ;

cat <<EOF > /home/core/fixup.sh ;
#!/usr/bin/env bash
cd "/workspace/src/github.com/aws/amazon-ssm-agent/agent" ;
gofmt -w /workspace/src/github.com/aws/amazon-ssm-agent/agent/agentlogstocloudwatch/cloudwatchlogspublisher/cloudwatchlogs_publisher_test.go ;
gofmt -w /workspace/src/github.com/aws/amazon-ssm-agent/agent/rip/riputil.go ;
gofmt -w /workspace/src/github.com/aws/amazon-ssm-agent/agent/s3util/riputil.go ;
gofmt -w /workspace/src/github.com/aws/amazon-ssm-agent/agent/session/datachannel/datachannel.go ;
go get golang.org/x/tools/cmd/goimports ;
goimports -w /workspace/src/github.com/aws/amazon-ssm-agent/agent/crypto/mocks/IBlockCipher.go ;
goimports -w /workspace/src/github.com/aws/amazon-ssm-agent/agent/health/mocks/IHealthCheck.go ;
goimports -w /workspace/src/github.com/aws/amazon-ssm-agent/agent/hibernation/mocks/IHibernate.go ;
goimports -w /workspace/src/github.com/aws/amazon-ssm-agent/agent/plugins/configurepackage/birdwatcher/facade/mocks/BirdwatcherFacade.go ;
goimports -w /workspace/src/github.com/aws/amazon-ssm-agent/agent/s3util/riputil.go ;
goimports -w /workspace/src/github.com/aws/amazon-ssm-agent/agent/session/communicator/mocks/IWebSocketChannel.go ;
goimports -w /workspace/src/github.com/aws/amazon-ssm-agent/agent/session/controlchannel/mocks/IControlChannel.go ;
goimports -w /workspace/src/github.com/aws/amazon-ssm-agent/agent/session/datachannel/mocks/IDataChannel.go ;
goimports -w /workspace/src/github.com/aws/amazon-ssm-agent/agent/session/plugins/sessionplugin/mocks/ISessionPlugin.go ;
goimports -w /workspace/src/github.com/aws/amazon-ssm-agent/agent/session/service/mocks/service.go ;
sed -i'' -e 's/go tool vet/go vet/' /workspace/src/github.com/aws/amazon-ssm-agent/Tools/src/checkstyle.sh ;
EOF

sudo chmod +x /home/core/fixup.sh ;

docker run --rm --name "${DOCKER_BUILD_BOX}" \
  -v "/home/core/fixup.sh":"/fixup.sh" \
  -v "${PWD}":"${DOCKER_WERKSPACE}" \
  -w "${DOCKER_WERKSPACE}" \
  "${DOCKER_GOLANG_TAG}" \
  /bin/bash -c '/fixup.sh && make build-linux ;'

mkdir -p "${BIN_DIR}" ;
sudo mkdir -p "${CONFIG_DIR}" ;

sudo mv -v bin/linux_amd64/* "${BIN_DIR}/" ;
sudo mv -v "amazon-ssm-agent.json.template" "${CONFIG_DIR}/amazon-ssm-agent.json" ;
sudo mv -v "seelog_unix.xml" "${CONFIG_DIR}/seelog.xml"

cd "$HOME" || exit ;

sudo rm -rf "/home/core/fixup.sh" ;
sudo rm -rf "${WERK_DIR}" ;
( docker rm -f "${DOCKER_BUILD_BOX}" || true )
( docker rmi "${DOCKER_GOLANG_TAG}" || true )

cat <<EOF | sudo tee "/etc/systemd/system/amazon-ssm-agent.service" ;
[Unit]
Description=amazon-ssm-agent
[Service]
Type=simple
WorkingDirectory=${BIN_DIR}
ExecStart=${BIN_DIR}/amazon-ssm-agent
KillMode=process
Restart=on-failure
RestartSec=15min
[Install]
WantedBy=network-online.target
EOF

sudo systemctl enable amazon-ssm-agent.service ;
