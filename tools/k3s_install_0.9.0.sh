#!/bin/sh
#rm -rf /bin/sh
#ln -s /bin/bash /bin/sh
#读取raptor.properties文件中的属性作为环境变

#是否使用GEdge容器调度平台,默认为
useGEdge=true
#如果使用GEdge平台，作为集群主机server端的node_token
node_token=K103dd8d3e5fd3af6b4a8033cf82b9b138d70a348bf9de66252fe29f680adf3e971::node:tokenrtc101

# shellcheck disable=SC2112
function uninstallagent() {
    set -x
    [ $(id -u) -eq 0 ] || exec sudo $0 $@
    /usr/local/bin/k3s-killall.sh
    if which systemctl; then
        systemctl disable k3s-agent
        systemctl reset-failed k3s-agent
        systemctl daemon-reload
    fi
    if which rc-update; then
        rc-update delete k3s-agent default
    fi
    rm -f /etc/systemd/system/k3s-agent.service
    rm -f /etc/systemd/system/k3s-agent.service.env
    remove_uninstall() {
        rm -f /usr/local/bin/k3s-agent-uninstall.sh
    }
    trap remove_uninstall EXIT
    if (ls /etc/systemd/system/k3s*.service || ls /etc/init.d/k3s*) >/dev/null 2>&1; then
        set +x; echo 'Additional k3s services installed, skipping uninstall of k3s'; set -x
        exit
    fi
    for cmd in kubectl crictl ctr; do
        if [ -L /usr/local/bin/$cmd ]; then
            rm -f /usr/local/bin/$cmd
        fi
    done
    rm -rf /etc/rancher/k3s
    rm -rf /var/lib/rancher/k3s/data
    rm -rf /var/lib/rancher/k3s/agent/*.crt
    rm -rf /var/lib/rancher/k3s/agent/*.key
    rm -rf /var/lib/rancher/k3s/agent/*.kubeconfig
    rm -rf /var/lib/rancher/k3s/agent/*.yaml
    rm -rf /var/lib/rancher/k3s/agent/etc
    rm -rf /var/lib/rancher/k3s/agent/kubelet
    rm -rf /var/lib/kubelet
    rm -f /usr/local/bin/k3s-killall.sh
}

# Get base images for kube
function get_docker_base_images(){
    docker pull mirrorgooglecontainers/kube-proxy-amd64:v1.11.3
    docker pull registry.cn-hangzhou.aliyuncs.com/launcher/pause:3.1
    docker pull coredns/coredns:1.1.3
    docker pull rancher/local-path-provisioner:v0.0.11
    
    docker tag mirrorgooglecontainers/kube-proxy-amd64:v1.11.3 k8s.gcr.io/kube-proxy-amd64:v1.11.3
    docker tag registry.cn-hangzhou.aliyuncs.com/launcher/pause:3.1  k8s.gcr.io/pause:3.1
    docker tag docker.io/coredns/coredns:1.1.3  k8s.gcr.io/coredns:1.1.3
}

# shellcheck disable=SC2112
function getrealmac() {
    #Collecting all physical interfaces's name and mac addresse
    declare -A NAME_TO_MAC
    set -e
    for f in /sys/class/net/*; do
      if [ -L $f ]; then
        name=`readlink $f`
        if echo $name | grep -v 'devices/virtual' > /dev/null; then
          eval $(ifconfig `basename $f` | head -n 1 | awk '{print "NAME_TO_MAC[\"",$1,"\"]=",$5}' | tr -d ' ')
        fi
      fi
    done

    function getRealMac()
    {
      local ifname=$1
      local bond=$2
      local pattern="Slave Interface $ifname"
      awk -v pattern="$pattern" '$0 ~ pattern, $0 ~ /^$/' $bond | awk '/Permanent HW addr/{print $4}' | tr -d ' '
    }

    #Trying to get the real mac when there's a bonding interface
    for name in "${!NAME_TO_MAC[@]}";  do
      for bond in /proc/net/bonding/*; do
        if grep $name /sys/devices/virtual/net/`basename $bond`/bonding/slaves > /dev/null; then
          MAC=`getRealMac $name $bond`
          if ! [ -z $MAC ]; then
            NAME_TO_MAC["$name"]="$MAC"
          fi
        fi
      done
    done

    set +e

    for k in ${!NAME_TO_MAC[@]}; do
       echo $k ${NAME_TO_MAC[$k]}
       MAC_NAME=$k
    done

    REAL_MAC=`ifconfig $MAC_NAME| grep ether | awk -F" " '{print $2}'`

    echo ${REAL_MAC}
    # shellcheck disable=SC2006
    # shellcheck disable=SC2209
    node_name=`echo ${REAL_MAC} | sed 's/://g'`
    if [ -n "${node_name}" ]; then
        node_name=${node_name}
    else
        echo "Please Check The Device's MAC And Then Run: export MAC=*****;export node_name=${MAC}"
        return
    fi
}

#检查是否开启GEdge配置，如果未开启配置，则直接跳过k3s安装
if $useGEdge
then
    echo ${node_token}
    echo "uninstall k3s-agent"
    uninstallagent
    echo "getMac"
    getrealmac
    echo "${node_name}"
    # shellcheck disable=SC2009
    ps -ef|grep "k3s agent"|grep -v "grep"|awk '{print $2}'|xargs -I{} kill -9 {}
    # shellcheck disable=SC2181
    [ $? -eq 0 ] &&echo "stop k3s-agent succeed"
    # shellcheck disable=SC2006
    echo "$SUDO"
    # shellcheck disable=SC2006
    check_jq
    DOCKER_DRIVER=`$SUDO docker info -f '{{json .}}'|jq '.CgroupDriver'| sed -r 's/.*"(.+)".*/\1/'`
    if [ -n "${DOCKER_DRIVER}" ]; then
	    DOCKER_DRIVER=${DOCKER_DRIVER}
    else
	    DOCKER_DRIVER=cgroupfs
    fi
    BIN_DIR=/usr/local/bin
    if [ ! -x ${BIN_DIR}/k3s ]; then
        echo "Downloading K3s"
        SKIP_DOWNLOAD=false
    else
        # shellcheck disable=SC2006
        k3sversion=`${BIN_DIR}/k3s --version|awk '{print $3}'`
	echo $k3sversion
        # shellcheck disable=SC2039
        # shellcheck disable=SC2193
        if [ -"${k3sversion}" == "v0.9.0" ]; then
            SKIP_DOWNLOAD=true
        else
            SKIP_DOWNLOAD=false
        fi
    fi

    function change_docker_driver(){
        check_jq
        CGROUP_DRIVER=$(docker info -f '{{json .}}'|jq '.CgroupDriver'| sed -r 's/.*"(.+)".*/\1/')
        DOCKER_VERSION=$(docker -v)
	NEED_RESTART_DOCKER=false
        if [ $? -eq  0 ];then
            echo "已安装Docker,版本号为$DOCKER_VERSION"
        else
            echo '机器上并未安装Docker。执行安装docker'
            yum install -y docker
        fi
        if [ $CGROUP_DRIVER == 'cgroupfs' ];then
            echo "Docker的Cgroup Driver为$CGROUP_DRIVER，无需更改"
        else
            echo "Docker的Cgroup Driver为$CGROUP_DRIVER，正在更改为cgroupfs"
            if [ -f /usr/lib/systemd/system/docker.service ];then
                echo "修改service文件"
                if [ `grep -c "=systemd" /usr/lib/systemd/system/docker.service` -ne 0  ];then
                    sed -i "s/systemd/cgroupfs/g" /usr/lib/systemd/system/docker.service
                else
                    if [ -f /etc/docker/daemon.json ];then
                        #判断有此文件
                        if [ `grep -c "exec-opts" /etc/docker/daemon.json` -eq 1 ];then
                            sed -i "s/=systemd/=cgroupfs/g" /etc/docker/daemon.json
                        fi
                    else
                        echo '没有找到daemon.json文件'
                    fi
                fi
                if [ `grep -c "registry-mirror" /usr/lib/systemd/system/docker.service` -eq 0 ];then
                    sed -i '/--exec-opt/a\          --registry-mirror=https://registry.docker-cn.com \\' /usr/lib/systemd/system/docker.service
                fi
            fi
	    echo 'Would restart docker'
	    NEED_RESTART_DOCKER=true
        fi
        if [ `grep -c "registry-mirror" /usr/lib/systemd/system/docker.service` -eq 0 ];then
            sed -i '/--exec-opt/a\          --registry-mirror=https://registry.docker-cn.com \\' /usr/lib/systemd/system/docker.service
	    NEED_RESTART_DOCKER=true
            echo 'Would restart docker'
	fi
	if [ $NEED_RESTART_DOCKER == true ];then
	    systemctl daemon-reload
            systemctl restart docker
	fi
    }

    function check_jq(){
        if [ `command -v jq` ];then
            echo 'jq 已经安装'
        else
            echo 'jq 未安装,开始安装json解析工具'
        #安装jq
            yum install jq -y
            if [ `command -v jq` ];then
                echo 'jq 成功安装'
            else
                echo 'jq 安装失败，请手动换源安装'
                exit 8
            fi
        fi
    }

    change_docker_driver
    get_docker_base_images
    curl http://pool.raptorchain.io/check_machine_online/mac=${node_name}
    curl -sfL  http://app.gravity.top:8085/install.sh | INSTALL_K3S_EXEC="agent --docker --server https://gserver.gravity.top:6443 --token ${node_token} --node-name ${node_name} --kubelet-arg cgroup-driver=${DOCKER_DRIVER} --kube-proxy-arg bind-address=127.0.0.1" INSTALL_K3S_VERSION="v0.9.0" INSTALL_K3S_SKIP_DOWNLOAD=${SKIP_DOWNLOAD} sh -s -
    systemctl daemon-reload
    systemctl start k3s-agent
    #nohup k3s agent --docker --server https://gserver.gravity.top:6443 --token ${node_token} 2>&1 >k3sagent.log &
    echo "agent start"
fi

echo "-------------------------------agent is start,please run: "sudo systemctl status k3s-agent -l"  to check status--------------------------"

