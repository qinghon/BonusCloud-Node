#!/bin/bash 

BASE_DIR="/opt/bcloud"
BOOTCONFIG="$BASE_DIR/scripts/bootconfig"
NODE_INFO="$BASE_DIR/node.db"
LOG_FILE="ins.log"

K8S_LOW="1.12.3"
DOC_LOW="1.11.1"

log(){
    if [ "$1" = "[error]" ]; then
        echo "[`date '+%Y-%m-%d %H:%M:%S'`] $1 $2" >>$LOG_FILE
        echo -e "[`date '+%Y-%m-%d %H:%M:%S'`] \033[31m $1 $2 \033[0m" 
    elif [ "$1" = "[info]" ]; then
        echo "[`date '+%Y-%m-%d %H:%M:%S'`] $1 $2" >>$LOG_FILE
    else
        echo "[`date '+%Y-%m-%d %H:%M:%S'`] [debug] $2" >>$LOG_FILE
    fi
}
function version_ge() { test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" == "$1"; }
check_doc(){
    retd=`which docker;echo $?`
    if [ $retd -ne 0 ]; then
        log "[info]" "docker not found"
        return 1
    else
        doc_v=`docker version |grep Version|grep -o '[0-9\.]*'|head -n 1`
        if version_ge $doc_v $doc_low ; then
            log "[info]" "docker version ok"
            return 0
        else
            log "[info]" "docker version fail"
            return 1
        fi
    fi
}
check_k8s(){
    reta=`which kubeadm;echo $?`
    retl=`which kubelet;echo $?`
    retc=`which kubectl;echo $?`
    if [ $reta -ne 0 ] || [ $retl -ne 0 ] || [ $retc -ne 0 ] ; then
        log "[info]" "k8s not found"
        return 1
    else 
        k8s_adm=`kubeadm version|grep -o '\"v[0-9\.]*\"'|grep -o '[0-9\.]*'`
        k8s_let=`kubelet --version|grep -o '[0-9\.]*'`
        k8s_ctl=`kubectl  version --short --client|grep -o '[0-9\.]*'`
        if version_ge $k8s_adm $k8s_low ; then
            log "[info]" "kubeadm version ok"
        else
            log "[info]" "kubeadm version fail"
            return 1
        fi
        if version_ge $k8s_let $k8s_low ; then
            log "[info]"  "kubelet version ok"
        else
            log "[info]"  "kubelet version fail"
            return 1
        fi
        if version_ge $k8s_ctl $k8s_low ; then
            log "[info]"  "kubectl version ok"
        else
            log "[info]"  "kubectl version fail"
            return 1
        fi
        return 0
    fi
}
check_apt(){
    ret=`which apt;echo $?`
    if [ $ret -ne 0 ]; then
        log "[error]" " apt not found !install fail"
        exit 1
    fi
    ret=`getconf LONG_BIT`
    if [ "$ret" -ne 64 ]; then
        log "[error]" " this is 64 system install script ,if you's not ,please install correspond system"
        exit 1
    fi
    
}
ins_docker(){
    if ! check_doc ; then
        log "[info]" "installing docker"
        apt install -y docker.io
    else
        log "[info]" " docker was found! skiped"
    fi
}
init(){
    echo >$LOG_FILE
    systemctl enable ntp
    systemctl start ntp

    check_apt  
    apt update 
    ins_docker
    mkdir -p /etc/cni/net.d
    mkdir -p $BASE_DIR/scripts
    mkdir -p $BASE_DIR/nodeapi 
    if [ ! -s $NODE_INFO ]; then
        touch $NODE_INFO
    else
        rm $NODE_INFO
        touch $NODE_INFO
    fi
    cp -r ./res/compute $BASE_DIR
}

ins_k8s(){
    if ! check_k8s ; then
        curl https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | apt-key add -
        cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main
EOF
        log "[info]" "installing k8s"
        apt update
        apt install -y kubeadm=1.12.3-00 kubectl=1.12.3-00 kubelet=1.12.3-00
        apt-mark hold kubelet kubeadm kubectl
        if ! check_k8s ; then
            log "[error]" "k8s install fail!"
            exit 1
        fi
    else
        log "[info]" " k8s was found! skip"
    fi
    
    docker pull registry.cn-beijing.aliyuncs.com/bxc_k8s_gcr_io/pause:arm-3.1
    docker pull registry.cn-beijing.aliyuncs.com/bxc_k8s_gcr_io/kube-proxy-arm:v1.12.3
    docker tag registry.cn-beijing.aliyuncs.com/bxc_k8s_gcr_io/pause:arm-3.1 k8s.gcr.io/pause:3.1
    docker tag registry.cn-beijing.aliyuncs.com/bxc_k8s_gcr_io/kube-proxy-arm:v1.12.3 k8s.gcr.io/kube-proxy:v1.12.3
    
    docker pull  registry.cn-beijing.aliyuncs.com/bxc_public/bxc-worker:v2-arm64

    docker tag registry.cn-beijing.aliyuncs.com/bxc_public/bxc-worker:v2-arm64 bxc-worker:v2
    cat <<EOF >  /etc/sysctl.d/k8s.conf
vm.swappiness = 0
net.ipv6.conf.default.forwarding = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
    sysctl -p /etc/sysctl.d/k8s.conf
    log "[info]" "k8s install over"
}
ins_node(){
    arch=`uname -m`
    curl -s -t 3 -m 5 "https://raw.githubusercontent.com/BonusCloud/BonusCloud-Node/master/img-modules/md5.txt" -o /tmp/md5.txt
    if [ ! -s "/tmp/md5.txt" ]; then
        log "[error]" " curl -t 3 -m 5 \"https://raw.githubusercontent.com/BonusCloud/BonusCloud-Node/master/img-modules/md5.txt\" -o /tmp/md5.txt"
        return
    fi
    for line in `grep "$arch" /tmp/md5.txt`
    do
        git_file_name=`echo $line | awk -F: '{print $1}'`
        git_md5_val=`echo $line | awk -F: '{print $2}'`
        file_path=`echo $line | awk -F: '{print $3}'`
        start_wait=`echo $line | awk -F: '{print $4}'`
        #local_md5_val=`md5sum $file_path | awk '{print $1}'`
    
        curl -s -t 3 -m 300 "https://raw.githubusercontent.com/BonusCloud/BonusCloud-Node/master/img-modules/$git_file_name" -o /tmp/$git_file_name
        download_md5=`md5sum /tmp/$git_file_name | awk '{print $1}'`
        if [ "$download_md5"x != "$git_md5_val"x ];then
            log "[error]" " download file /tmp/$git_file_name md5 $download_md5 different from git md5 $git_md5_val, ignore this update and continue ..."
            continue
        else
            log "[info]" " /tmp/$git_file_name download success."
            #cp -f $file_path ${file_path}.bak > /dev/null
            cp -f /tmp/$git_file_name $file_path > /dev/null
            chmod +x $file_path > /dev/null            
        fi
        
    done
    cat <<EOF >/lib/systemd/system/bxc-node.service
[Unit]
Description=bxc node app
After=network.target

[Service]
ExecStart=/opt/bcloud/nodeapi/node
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable bxc-node
    systemctl start bxc-node
    isactive=`ps aux | grep -v grep | grep "nodeapi/node" > /dev/null; echo $?`
    if [ $isactive -ne 0 ];then
        log "[error]" " node start faild, rollback and restart"
        systemctl restart bxc-node
    else
        log "[info]" " node start success."
    fi
}

ins_bxcup(){
    cp ./res/bxc-update /etc/cron.daily/bxc-update
    chmod +x /etc/cron.daily/bxc-update
    log "[info]" " install bxc_update over"
}
verifty(){
    if [ ! -s $BASE_DIR/bxc-network ]; then
        return 1
    fi
    if [ ! -s $BASE_DIR/nodeapi/node ]; then
        return 2
    fi
    if [ ! -s $BASE_DIR/compute/10-mynet.conflist ]; then
        return 3
    fi
    if [ ! -s $BASE_DIR/compute/99-loopback.conf ]; then
        return 4
    fi
    log "[info]" " verifty file over"
    return 0 
}

case $1 in
    init )
        init
        ;;
    k8s )
        ins_k8s
        ;;
    node )
        ins_node
        ;;
    bxcup )
        ins_bxcup
        ;;
    * )
        init
        ins_k8s
        ins_node
        ins_bxcup
        if ! verifty ; then
            echo "install faild! return $res"
            log "[error]" " verifty error ,install fail"
        else
            log "[info]" "all install over"
        fi
        ;;
esac
