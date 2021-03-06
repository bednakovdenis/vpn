#!/bin/bash
#


export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

exiterr() { echo "Error: $1" >&2; exit 1; }
bigecho() { echo "## $1"; }
bigecho2() { printf '\e[2K\r%s' "## $1"; }

check_ip() {
  IP_REGEX='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$IP_REGEX"
}

check_dns_name() {
  FQDN_REGEX='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
  printf '%s' "$1" | tr -d '\n' | grep -Eq "$FQDN_REGEX"
}

check_run_as_root() {
  if [ "$(id -u)" != 0 ]; then
    exiterr "Script must be run as root. Try 'sudo bash $0'"
  fi
}

check_os_type() {
  os_arch=$(uname -m | tr -dc 'A-Za-z0-9_-')
  if grep -qs -e "release 7" -e "release 8" /etc/redhat-release; then
    os_type=centos
    if grep -qs "Red Hat" /etc/redhat-release; then
      os_type=rhel
    fi
    if grep -qs "release 7" /etc/redhat-release; then
      os_ver=7
    elif grep -qs "release 8" /etc/redhat-release; then
      os_ver=8
    fi
  elif grep -qs "Amazon Linux release 2" /etc/system-release; then
    os_type=amzn
    os_ver=2
  else
    os_type=$(lsb_release -si 2>/dev/null)
    [ -z "$os_type" ] && [ -f /etc/os-release ] && os_type=$(. /etc/os-release && printf '%s' "$ID")
    case $os_type in
      [Uu]buntu)
        os_type=ubuntu
        ;;
      [Dd]ebian)
        os_type=debian
        ;;
      [Rr]aspbian)
        os_type=raspbian
        ;;
      *)
        exiterr "Этот скрипт поддерживает только Ubuntu, Debian, CentOS / RHEL 7/8 и Amazon Linux 2.."
        ;;
    esac
    os_ver=$(sed 's/\..*//' /etc/debian_version | tr -dc 'A-Za-z0-9')
  fi
}

get_update_url() {
  update_url=vpnupgrade
  if [ "$os_type" = "centos" ] || [ "$os_type" = "rhel" ]; then
    update_url=vpnupgrade-centos
  elif [ "$os_type" = "amzn" ]; then
    update_url=vpnupgrade-amzn
  fi
  update_url="https://git.io/$update_url"
}

check_swan_install() {
  ipsec_ver=$(/usr/local/sbin/ipsec --version 2>/dev/null)
  swan_ver=$(printf '%s' "$ipsec_ver" | sed -e 's/Linux Libreswan //' -e 's/ (netkey).*//' -e 's/^U//' -e 's/\/K.*//')
  if ( ! grep -qs "hwdsl2 VPN script" /etc/sysctl.conf && ! grep -qs "hwdsl2" /opt/src/run.sh ) \
    || ! printf '%s' "$ipsec_ver" | grep -q "Libreswan"; then
cat 1>&2 <<'EOF'
Error: Перед настройкой IKEv2 необходимо сначала настроить сервер IPsec VPN..
       See: https://github.com/hwdsl2/setup-ipsec-vpn
EOF
    exit 1
  fi

  case $swan_ver in
    3.2[35679]|3.3[12]|4.*)
      true
      ;;
    *)
      get_update_url
cat 1>&2 <<EOF
Error: Версия Libreswan "$ swan_ver" не поддерживается.
        Для этого скрипта требуется одна из следующих версий:
        3.23, 3.25–3.27, 3.29, 3.31–3.32 или 4.x
        Чтобы обновить Libreswan, запустите:
       wget $update_url -O vpnupgrade.sh
       sudo sh vpnupgrade.sh
EOF
      exit 1
      ;;
  esac
}

check_utils_exist() {
  command -v certutil >/dev/null 2>&1 || exiterr "'certutil' not found. Abort."
  command -v pk12util >/dev/null 2>&1 || exiterr "'pk12util' not found. Abort."
}

check_container() {
  in_container=0
  if grep -qs "hwdsl2" /opt/src/run.sh; then
    in_container=1
  fi
}

show_usage() {
  if [ -n "$1" ]; then
    echo "Error: $1" >&2;
  fi
cat 1>&2 <<EOF
Usage: bash $0 [options]

Options:
  --auto                        run Cicada3301 setup in auto mode using default options (for initial Cicada3301 setup only)
  --addclient [client name]     добавить нового клиента Cicada3301, используя параметры по умолчанию (после настройки Cicada3301)
  --exportclient [client name]  экспортировать существующий клиент Cicada3301 с использованием параметров по умолчанию (после настройки Cicada3301)
  --listclients                 перечислить имена существующих клиентов Cicada3301 (после настройки Cicada3301)
  --removeIKEv2                 удалить Cicada3301 и удалить все сертификаты и ключи из базы данных IPsec
  -h, --help                    sкак это справочное сообщение и выход

Чтобы настроить Cicada3301 или параметры клиента, запустите этот сценарий без аргументов..
EOF
  exit 1
}

check_IKEv2_exists() {
  grep -qs "conn ikev2-cp" /etc/ipsec.conf || [ -f /etc/ipsec.d/ikev2.conf ]
}

check_client_name() {
  ! { [ "${#client_name}" -gt "64" ] || printf '%s' "$client_name" | LC_ALL=C grep -q '[^A-Za-z0-9_-]\+' \
    || case $client_name in -*) true;; *) false;; esac; }
}

check_client_cert_exists() {
  certutil -L -d sql:/etc/ipsec.d -n "$client_name" >/dev/null 2>&1
}

check_arguments() {
  if [ "$use_defaults" = "1" ]; then
    if check_IKEv2_exists; then
      echo "Предупреждение: игнорирование параметра --auto. Используйте '-h' для информации об использовании." >&2
      echo >&2
    fi
  fi
  if [ "$((add_client_using_defaults + export_client_using_defaults + list_clients))" -gt 1 ]; then
    show_usage "Неверные параметры. Укажите только один из '--addclient', '--exportclient' или же '--listclients'."
  fi
  if [ "$add_client_using_defaults" = "1" ]; then
    ! check_IKEv2_exists && exiterr "Перед добавлением нового клиента необходимо сначала настроить Cicada3301.."
    if [ -z "$client_name" ] || ! check_client_name; then
      exiterr "Неверное имя клиента. Используйте только одно слово, никаких специальных символов, кроме'-' или '_'."
    elif check_client_cert_exists; then
      exiterr "Неверное имя клиента. Клиент '$client_name' уже существует."
    fi
  fi
  if [ "$export_client_using_defaults" = "1" ]; then
    ! check_IKEv2_exists && exiterr "Перед экспортом конфигурации клиента необходимо сначала настроить Cicada3301.."
    get_server_address
    if [ -z "$client_name" ] || ! check_client_name \
      || [ "$client_name" = "IKEv2 VPN CA" ] || [ "$client_name" = "$server_addr" ] \
      || ! check_client_cert_exists; then
      exiterr "Неверное имя клиента или клиент не существует."
    fi
  fi
  if [ "$list_clients" = "1" ]; then
    ! check_IKEv2_exists && exiterr "Перед перечислением клиентов необходимо сначала настроить IKEv2.."
  fi
  if [ "$remove_IKEv2" = "1" ]; then
    ! check_IKEv2_exists && exiterr "Невозможно удалить Cicada3301, потому что он не был настроен на этом сервере."
    if [ "$((add_client_using_defaults + export_client_using_defaults + list_clients + use_defaults))" -gt 0 ]; then
      show_usage "Неверные параметры. '--removeIKEv2' нельзя указать с другими параметрами."
    fi
  fi
}

check_server_dns_name() {
  if [ -n "$VPN_DNS_NAME" ]; then
    check_dns_name "$VPN_DNS_NAME" || exiterr "Неверное DNS-имя. 'VPN_DNS_NAME' должно быть полное доменное имя (FQDN)."
  fi
}

check_custom_dns() {
  if { [ -n "$VPN_DNS_SRV1" ] && ! check_ip "$VPN_DNS_SRV1"; } \
    || { [ -n "$VPN_DNS_SRV2" ] && ! check_ip "$VPN_DNS_SRV2"; } then
    exiterr "Указанный DNS-сервер недействителен."
  fi
}

check_ca_cert_exists() {
  if certutil -L -d sql:/etc/ipsec.d -n "IKEv2 VPN CA" >/dev/null 2>&1; then
    exiterr "Certificate 'IKEv2 VPN CA' already exists."
  fi
}

check_server_cert_exists() {
  if certutil -L -d sql:/etc/ipsec.d -n "$server_addr" >/dev/null 2>&1; then
    echo "Ошибка: сертификат '$server_addr' уже существует." >&2
    echo "Прервать. Никаких изменений не было." >&2
    exit 1
  fi
}

check_swan_ver() {
  if [ "$in_container" = "0" ]; then
    swan_ver_url="https://dl.ls20.com/v1/$os_type/$os_ver/swanverIKEv2?arch=$os_arch&ver=$swan_ver&auto=$use_defaults"
  else
    swan_ver_url="https://dl.ls20.com/v1/docker/$os_arch/swanverIKEv2?ver=$swan_ver&auto=$use_defaults"
  fi
  swan_ver_latest=$(wget -t 3 -T 15 -qO- "$swan_ver_url")
}

run_swan_update() {
  get_update_url
  TMPDIR=$(mktemp -d /tmp/vpnupg.XXX 2>/dev/null)
  if [ -d "$TMPDIR" ]; then
    set -x
    if wget -t 3 -T 30 -q -O "$TMPDIR/vpnupg.sh" "$update_url"; then
      /bin/sh "$TMPDIR/vpnupg.sh"
    fi
    { set +x; } 2>&-
    [ ! -s "$TMPDIR/vpnupg.sh" ] && echo "Ошибка: не удалось загрузить скрипт обновления.." >&2
    /bin/rm -f "$TMPDIR/vpnupg.sh"
    /bin/rmdir "$TMPDIR"
  else
    echo "Ошибка: не удалось создать временный каталог.." >&2
  fi
  read -n 1 -s -r -p "Нажмите любую клавишу, чтобы продолжить настройку Cicada3301...."
  echo
}

select_swan_update() {
  if printf '%s' "$swan_ver_latest" | grep -Eq '^([3-9]|[1-9][0-9])\.([0-9]|[1-9][0-9])$' \
    && [ "$swan_ver" != "$swan_ver_latest" ] \
    && printf '%s\n%s' "$swan_ver" "$swan_ver_latest" | sort -C -V; then
    echo "Примечание: более новая версия Libreswan ($swan_ver_latest) доступен."
    echo "      Перед настройкой Cicada3301 рекомендуется обновить Libreswan.."
    if [ "$in_container" = "0" ]; then
      echo
      printf "Хотите обновить Libreswan? [Y/n] "
      read -r response
      case $response in
        [yY][eE][sS]|[yY]|'')
          echo
          run_swan_update
          ;;
        *)
          echo
          ;;
      esac
    else
      echo "      Чтобы обновить этот образ Docker, см.: https://git.io/updatedockervpn"
      echo
      printf "Вы все равно хотите продолжить? [y/N] "
      read -r response
      case $response in
        [yY][eE][sS]|[yY])
          echo
          ;;
        *)
          echo "Прервать. Никаких изменений не было."
          exit 1
          ;;
      esac
    fi
  fi
}

show_welcome_message() {
cat <<'EOF'
Добро пожаловать! Используйте этот сценарий для настройки Cicada3301 после настройки собственного сервера IPsec VPN.
Кроме того, вы можете вручную настроить Cicada3301. См .: https://git.io/Cicada3301

Прежде чем приступить к настройке, мне нужно задать вам несколько вопросов.
Вы можете использовать параметры по умолчанию и просто нажать Enter, если вас устраивает..

EOF
}

show_start_message() {
  bigecho "Запуск настройки Cicada3301 в автоматическом режиме с параметрами по умолчанию."
}

show_add_client_message() {
  bigecho "Добавление нового клиента Cicada3301 '$client_name', с использованием параметров по умолчанию."
}

show_export_client_message() {
  bigecho "Экспорт существующего клиента Cicada3301 '$client_name', с использованием параметров по умолчанию."
}

get_export_dir() {
  export_to_home_dir=0
  if grep -qs "hwdsl2" /opt/src/run.sh; then
    export_dir="/etc/ipsec.d/"
  else
    export_dir=~/
    if [ -n "$SUDO_USER" ] && getent group "$SUDO_USER" >/dev/null 2>&1; then
      user_home_dir=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
      if [ -d "$user_home_dir" ] && [ "$user_home_dir" != "/" ]; then
        export_dir="$user_home_dir/"
        export_to_home_dir=1
      fi
    fi
  fi
}

get_server_ip() {
  bigecho2 "Пытается автоматически определить IP этого сервера..."
  public_ip=$(dig @resolver1.opendns.com -t A -4 myip.opendns.com +short)
  check_ip "$public_ip" || public_ip=$(wget -t 3 -T 15 -qO- http://ipv4.icanhazip.com)
}

get_server_address() {
  server_addr=$(grep -s "leftcert=" /etc/ipsec.d/ikev2.conf | cut -f2 -d=)
  [ -z "$server_addr" ] && server_addr=$(grep -s "leftcert=" /etc/ipsec.conf | cut -f2 -d=)
  check_ip "$server_addr" || check_dns_name "$server_addr" || exiterr "Не удалось получить адрес VPN-сервера."
}

list_existing_clients() {
  echo "Проверка существующих клиентов Cicada3301..."
  certutil -L -d sql:/etc/ipsec.d | grep -v -e '^$' -e 'IKEv2 VPN CA' -e '\.' | tail -n +3 | cut -f1 -d ' '
}

enter_server_address() {
  echo "Вы хотите, чтобы клиенты Cicada3301 подключались к этому серверу с использованием DNS-имени?,"
  printf "например vpn.example.com вместо его IP-адреса? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      use_dns_name=1
      echo
      ;;
    *)
      use_dns_name=0
      echo
      ;;
  esac

  if [ "$use_dns_name" = "1" ]; then
    read -rp "Введите DNS-имя этого VPN-сервера: " server_addr
    until check_dns_name "$server_addr"; do
      echo "Неверное DNS-имя. Вы должны заполнить полное доменное имя (FQDN)."
      read -rp "Введите DNS-имя этого VPN-сервера: " server_addr
    done
  else
    get_server_ip
    echo
    echo
    read -rp "Введите IPv4-адрес этого VPN-сервера: [$public_ip] " server_addr
    [ -z "$server_addr" ] && server_addr="$public_ip"
    until check_ip "$server_addr"; do
      echo "Неверный IP-адрес."
      read -rp "Введите IPv4-адрес этого VPN-сервера: [$public_ip] " server_addr
      [ -z "$server_addr" ] && server_addr="$public_ip"
    done
  fi
}

enter_client_name() {
  echo
  echo "Укажите имя для клиента Cicada3301.."
  echo "Используйте только одно слово, никаких специальных символов, кроме '-' а также '_'."
  read -rp "имя клиента: " client_name
  while [ -z "$client_name" ] || ! check_client_name || check_client_cert_exists; do
    if [ -z "$client_name" ] || ! check_client_name; then
      echo "Неверное имя клиента."
    else
      echo "Неверное имя клиента. Клиент '$client_name' уже существует."
    fi
    read -rp "имя клиента: " client_name
  done
}

enter_client_name_with_defaults() {
  echo
  echo "Укажите имя для клиента Cicada3301.."
  echo "Используйте только одно слово, никаких специальных символов, кроме '-' а также '_'."
  read -rp "имя клиента: [vpnclient] " client_name
  [ -z "$client_name" ] && client_name=vpnclient
  while ! check_client_name || check_client_cert_exists; do
      if ! check_client_name; then
        echo "Неверное имя клиента."
      else
        echo "Неверное имя клиента. Клиент '$client_name' уже существует."
      fi
    read -rp "Имя клиента: [vpnclient] " client_name
    [ -z "$client_name" ] && client_name=vpnclient
  done
}

enter_client_name_for_export() {
  echo
  list_existing_clients
  get_server_address
  echo
  read -rp "Введите имя клиента Cicada3301 для экспорта: " client_name
  while [ -z "$client_name" ] || ! check_client_name \
    || [ "$client_name" = "IKEv2 VPN CA" ] || [ "$client_name" = "$server_addr" ] \
    || ! check_client_cert_exists; do
    echo "Неверное имя клиента или клиент не существует."
    read -rp "Введите имя клиента Cicada3301 для экспорта: " client_name
  done
}

enter_client_cert_validity() {
  echo
  echo "Укажите срок действия (в месяцах) для этого сертификата клиента VPN."
  read -rp "Введите число от 1 до 120: [120] " client_validity
  [ -z "$client_validity" ] && client_validity=120
  while printf '%s' "$client_validity" | LC_ALL=C grep -q '[^0-9]\+' \
    || [ "$client_validity" -lt "1" ] || [ "$client_validity" -gt "120" ] \
    || [ "$client_validity" != "$((10#$client_validity))" ]; do
    echo "Недействительный срок действия."
    read -rp "Введите число от 1 до 120: [120] " client_validity
    [ -z "$client_validity" ] && client_validity=120
  done
}

enter_custom_dns() {
  echo
  echo "По умолчанию клиенты настроены на использование Google Public DNS, когда VPN активен.."
  printf "Вы хотите указать собственные DNS-серверы для Cicada3301?? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      use_custom_dns=1
      ;;
    *)
      use_custom_dns=0
      dns_server_1=8.8.8.8
      dns_server_2=8.8.4.4
      dns_servers="8.8.8.8 8.8.4.4"
      ;;
  esac

  if [ "$use_custom_dns" = "1" ]; then
    read -rp "Введите основной DNS-сервер: " dns_server_1
    until check_ip "$dns_server_1"; do
      echo "Неверный DNS-сервер."
      read -rp "Введите основной DNS-сервер: " dns_server_1
    done

    read -rp "Введите вторичный DNS-сервер (введите, чтобы пропустить): " dns_server_2
    until [ -z "$dns_server_2" ] || check_ip "$dns_server_2"; do
      echo "Неверный DNS-сервер."
      read -rp "Введите вторичный DNS-сервер (введите, чтобы пропустить): " dns_server_2
    done

    if [ -n "$dns_server_2" ]; then
      dns_servers="$dns_server_1 $dns_server_2"
    else
      dns_servers="$dns_server_1"
    fi
  else
    echo "Использование Google Public DNS (8.8.8.8, 8.8.4.4)."
  fi
  echo
}

check_mobike_support() {
  mobike_support=1
  if uname -m | grep -qi -e '^arm' -e '^aarch64'; then
    modprobe -q configs
    if [ -f /proc/config.gz ]; then
      if ! zcat /proc/config.gz | grep -q "CONFIG_XFRM_MIGRATE=y"; then
        mobike_support=0
      fi
    else
      mobike_support=0
    fi
  fi

  kernel_conf="/boot/config-$(uname -r)"
  if [ -f "$kernel_conf" ]; then
    if ! grep -qs "CONFIG_XFRM_MIGRATE=y" "$kernel_conf"; then
      mobike_support=0
    fi
  fi

  # Linux kernels on Ubuntu do not support MOBIKE
  if [ "$in_container" = "0" ]; then
    if [ "$os_type" = "ubuntu" ] || uname -v | grep -qi ubuntu; then
      mobike_support=0
    fi
  else
    if uname -v | grep -qi ubuntu; then
      mobike_support=0
    fi
  fi

  if [ "$mobike_support" = "1" ]; then
    bigecho2 "Проверка наличия МОБИЛЬНОЙ поддержки ... доступно"
  else
    bigecho2 "Проверка наличия МОБИЛЬНОЙ поддержки ... недоступно"
  fi
}

select_mobike() {
  echo
  mobike_enable=0
  if [ "$mobike_support" = "1" ]; then
    echo
    echo "Расширение MOBIKE Cicada3301 позволяет клиентам VPN изменять точки подключения к сети.,"
    echo "например переключаться между мобильными данными и Wi-Fi и поддерживать туннель IPsec на новом IP."
    echo
    printf "Вы хотите включить поддержку MOBIKE? [Y/n] "
    read -r response
    case $response in
      [yY][eE][sS]|[yY]|'')
        mobike_enable=1
        ;;
      *)
        mobike_enable=0
        ;;
    esac
  fi
}

select_p12_password() {
cat <<'EOF'

Конфигурация клиента будет экспортирована как файлы .p12, .sswan и .mobileconfig,
которые содержат сертификат клиента, закрытый ключ и сертификат CA.
Чтобы защитить эти файлы, этот сценарий может сгенерировать для вас случайный пароль,
который будет отображаться по завершении.

EOF

  printf "Вы хотите вместо этого указать свой собственный пароль? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      use_own_password=1
      echo
      ;;
    *)
      use_own_password=0
      echo
      ;;
  esac
}

select_menu_option() {
  echo "Cicada3301 уже настроен на этом сервере."
  echo
  echo "Выберите вариант:"
  echo "  1) Добавить нового клиента"
  echo "  2) Экспорт конфигурации для существующего клиента"
  echo "  3) Список существующих клиентов"
  echo "  4) Удалить Cicada3301"
  echo "  5) Exit"
  read -rp "Вариант: " selected_option
  until [[ "$selected_option" =~ ^[1-5]$ ]]; do
    printf '%s\n' "$selected_option: неверный выбор."
    read -rp "Вариант: " selected_option
  done
}

confirm_setup_options() {
cat <<EOF
Теперь мы готовы к настройке Cicada3301. Ниже приведены выбранные вами параметры настройки.
Пожалуйста, проверьте еще раз, прежде чем продолжить!

======================================

Адрес VPN-сервера: $server_addr
Имя клиента VPN: $client_name

EOF

  if [ "$client_validity" = "1" ]; then
    echo "Сертификат клиента действителен: 1 месяц"
  else
    echo "Сертификат клиента действителен для: $client_validity месяцы"
  fi

  if [ "$mobike_support" = "1" ]; then
    if [ "$mobike_enable" = "1" ]; then
      echo "Поддержка MOBIKE: Enable"
    else
      echo "Поддержка MOBIKE: Disable"
    fi
  else
    echo "Поддержка MOBIKE: Not available"
  fi

cat <<EOF
DNS сервер (ы): $dns_servers

======================================

EOF

  printf "Вы хотите продолжить? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      echo
      ;;
    *)
      echo "Прервать. Никаких изменений не было."
      exit 1
      ;;
  esac
}

create_client_cert() {
  bigecho2 "Создание сертификата клиента..."

  sleep $((RANDOM % 3 + 1))

  certutil -z <(head -c 1024 /dev/urandom) \
    -S -c "IKEv2 VPN CA" -n "$client_name" \
    -s "O=IKEv2 VPN,CN=$client_name" \
    -k rsa -v "$client_validity" \
    -d sql:/etc/ipsec.d -t ",," \
    --keyUsage digitalSignature,keyEncipherment \
    --extKeyUsage serverAuth,clientAuth -8 "$client_name" >/dev/null 2>&1 || exiterr "Не удалось создать сертификат клиента."
}

export_p12_file() {
  bigecho2 "Создание конфигурации клиента..."

  if [ "$use_own_password" = "1" ]; then
cat <<'EOF'


Введите * безопасный * пароль для защиты файлов конфигурации клиента.
При импорте на устройство iOS или macOS этот пароль не может быть пустым..

EOF
  else
    p12_password=$(LC_CTYPE=C tr -dc 'A-HJ-NPR-Za-km-z2-9' < /dev/urandom | head -c 16)
    [ -z "$p12_password" ] && exiterr "Не удалось сгенерировать случайный пароль для .p12 file."
  fi

  p12_file="$export_dir$client_name.p12"
  if [ "$use_own_password" = "1" ]; then
    pk12util -d sql:/etc/ipsec.d -n "$client_name" -o "$p12_file" || exit 1
  else
    pk12util -W "$p12_password" -d sql:/etc/ipsec.d -n "$client_name" -o "$p12_file" >/dev/null || exit 1
  fi

  if [ "$export_to_home_dir" = "1" ]; then
    chown "$SUDO_USER:$SUDO_USER" "$p12_file"
  fi
  chmod 600 "$p12_file"
}

install_base64_uuidgen() {
  if ! command -v base64 >/dev/null 2>&1 || ! command -v uuidgen >/dev/null 2>&1; then
    bigecho2 "Установка необходимых пакетов..."
    if [ "$os_type" = "ubuntu" ] || [ "$os_type" = "debian" ] || [ "$os_type" = "raspbian" ]; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get -yqq update || exiterr "'apt-get update' не смогли."
    fi
  fi
  if ! command -v base64 >/dev/null 2>&1; then
    if [ "$os_type" = "ubuntu" ] || [ "$os_type" = "debian" ] || [ "$os_type" = "raspbian" ]; then
      apt-get -yqq install coreutils >/dev/null || exiterr "'apt-get install' не смогли."
    else
      yum -y -q install coreutils >/dev/null || exiterr "'yum install' не смогли."
    fi
  fi
  if ! command -v uuidgen >/dev/null 2>&1; then
    if [ "$os_type" = "ubuntu" ] || [ "$os_type" = "debian" ] || [ "$os_type" = "raspbian" ]; then
      apt-get -yqq install uuid-runtime >/dev/null || exiterr "'apt-get install' не смогли."
    else
      yum -y -q install util-linux >/dev/null || exiterr "'yum install' не смогли."
    fi
  fi
}

create_mobileconfig() {
  [ -z "$server_addr" ] && get_server_address

  p12_base64=$(base64 -w 52 "$export_dir$client_name.p12")
  [ -z "$p12_base64" ] && exiterr "Не удалось закодировать .p12 file."

  ca_base64=$(certutil -L -d sql:/etc/ipsec.d -n "IKEv2 VPN CA" -a | grep -v CERTIFICATE)
  [ -z "$ca_base64" ] && exiterr "Не удалось закодировать сертификат IKEv2 CA."

  uuid1=$(uuidgen)
  [ -z "$uuid1" ] && exiterr "Не удалось сгенерировать значение UUID."

  mc_file="$export_dir$client_name.mobileconfig"

cat > "$mc_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>IKEv2</key>
      <dict>
        <key>AuthenticationMethod</key>
        <string>Certificate</string>
        <key>ChildSecurityAssociationParameters</key>
        <dict>
          <key>DiffieHellmanGroup</key>
          <integer>14</integer>
          <key>EncryptionAlgorithm</key>
          <string>AES-128-GCM</string>
          <key>LifeTimeInMinutes</key>
          <integer>1410</integer>
        </dict>
        <key>DeadPeerDetectionRate</key>
        <string>Medium</string>
        <key>DisableRedirect</key>
        <true/>
        <key>EnableCertificateRevocationCheck</key>
        <integer>0</integer>
        <key>EnablePFS</key>
        <integer>0</integer>
        <key>IKESecurityAssociationParameters</key>
        <dict>
          <key>DiffieHellmanGroup</key>
          <integer>14</integer>
          <key>EncryptionAlgorithm</key>
          <string>AES-256</string>
          <key>IntegrityAlgorithm</key>
          <string>SHA2-256</string>
          <key>LifeTimeInMinutes</key>
          <integer>1410</integer>
        </dict>
        <key>LocalIdentifier</key>
        <string>$client_name</string>
        <key>PayloadCertificateUUID</key>
        <string>$uuid1</string>
        <key>OnDemandEnabled</key>
        <integer>0</integer>
        <key>OnDemandRules</key>
        <array>
          <dict>
          <key>Action</key>
          <string>Connect</string>
          </dict>
        </array>
        <key>RemoteAddress</key>
        <string>$server_addr</string>
        <key>RemoteIdentifier</key>
        <string>$server_addr</string>
        <key>UseConfigurationAttributeInternalIPSubnet</key>
        <integer>0</integer>
      </dict>
      <key>IPv4</key>
      <dict>
        <key>OverridePrimary</key>
        <integer>1</integer>
      </dict>
      <key>PayloadDescription</key>
      <string>Configures VPN settings</string>
      <key>PayloadDisplayName</key>
      <string>VPN</string>
      <key>PayloadIdentifier</key>
      <string>com.apple.vpn.managed.$(uuidgen)</string>
      <key>PayloadType</key>
      <string>com.apple.vpn.managed</string>
      <key>PayloadUUID</key>
      <string>$(uuidgen)</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>Proxies</key>
      <dict>
        <key>HTTPEnable</key>
        <integer>0</integer>
        <key>HTTPSEnable</key>
        <integer>0</integer>
      </dict>
      <key>UserDefinedName</key>
      <string>$server_addr</string>
      <key>VPNType</key>
      <string>IKEv2</string>
    </dict>
    <dict>
      <key>PayloadCertificateFileName</key>
      <string>$client_name</string>
      <key>PayloadContent</key>
      <data>
$p12_base64
      </data>
      <key>PayloadDescription</key>
      <string>Adds a PKCS#12-formatted certificate</string>
      <key>PayloadDisplayName</key>
      <string>$client_name</string>
      <key>PayloadIdentifier</key>
      <string>com.apple.security.pkcs12.$(uuidgen)</string>
      <key>PayloadType</key>
      <string>com.apple.security.pkcs12</string>
      <key>PayloadUUID</key>
      <string>$uuid1</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
    <dict>
      <key>PayloadContent</key>
      <data>
$ca_base64
      </data>
      <key>PayloadCertificateFileName</key>
      <string>ikev2vpnca</string>
      <key>PayloadDescription</key>
      <string>Adds a CA root certificate</string>
      <key>PayloadDisplayName</key>
      <string>Certificate Authority (CA)</string>
      <key>PayloadIdentifier</key>
      <string>com.apple.security.root.$(uuidgen)</string>
      <key>PayloadType</key>
      <string>com.apple.security.root</string>
      <key>PayloadUUID</key>
      <string>$(uuidgen)</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
  </array>
  <key>PayloadDisplayName</key>
  <string>IKEv2 VPN ($server_addr)</string>
  <key>PayloadIdentifier</key>
  <string>com.apple.vpn.managed.$(uuidgen)</string>
  <key>PayloadRemovalDisallowed</key>
  <false/>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>$(uuidgen)</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>
EOF

  if [ "$export_to_home_dir" = "1" ]; then
    chown "$SUDO_USER:$SUDO_USER" "$mc_file"
  fi
  chmod 600 "$mc_file"
}

create_android_profile() {
  [ -z "$server_addr" ] && get_server_address

  p12_base64_oneline=$(base64 -w 52 "$export_dir$client_name.p12" | sed 's/$/\\n/' | tr -d '\n')
  [ -z "$p12_base64_oneline" ] && exiterr "Не удалось закодировать .p12 file."

  uuid2=$(uuidgen)
  [ -z "$uuid2" ] && exiterr "Не удалось сгенерировать значение UUID."

  sswan_file="$export_dir$client_name.sswan"

cat > "$sswan_file" <<EOF
  "uuid": "$uuid2",
  "name": "IKEv2 VPN ($server_addr)",
  "type": "ikev2-cert",
  "remote": {
    "addr": "$server_addr"
  },
  "local": {
    "p12": "$p12_base64_oneline",
    "rsa-pss": "true"
  },
  "ike-proposal": "aes256-sha256-modp2048",
  "esp-proposal": "aes128gcm16"
}
EOF

  if [ "$export_to_home_dir" = "1" ]; then
    chown "$SUDO_USER:$SUDO_USER" "$sswan_file"
  fi
  chmod 600 "$sswan_file"
}

create_ca_server_certs() {
  bigecho2 "Создание сертификатов CA и серверов..."

  certutil -z <(head -c 1024 /dev/urandom) \
    -S -x -n "IKEv2 VPN CA" \
    -s "O=IKEv2 VPN,CN=IKEv2 VPN CA" \
    -k rsa -v 120 \
    -d sql:/etc/ipsec.d -t "CT,," -2 >/dev/null 2>&1 <<ANSWERS || exiterr "Не удалось создать CA сертификат."
y

N
ANSWERS

  sleep $((RANDOM % 3 + 1))

  if [ "$use_dns_name" = "1" ]; then
    certutil -z <(head -c 1024 /dev/urandom) \
      -S -c "IKEv2 CA" -n "$server_addr" \
      -s "O=IKEv2,CN=$server_addr" \
      -k rsa -v 120 \
      -d sql:/etc/ipsec.d -t ",," \
      --keyUsage digitalSignature,keyEncipherment \
      --extKeyUsage serverAuth \
      --extSAN "dns:$server_addr" >/dev/null 2>&1 || exiterr "Не удалось создать сертификат сервера."
  else
    certutil -z <(head -c 1024 /dev/urandom) \
      -S -c "IKEv2 VPN CA" -n "$server_addr" \
      -s "O=IKEv2 VPN,CN=$server_addr" \
      -k rsa -v 120 \
      -d sql:/etc/ipsec.d -t ",," \
      --keyUsage digitalSignature,keyEncipherment \
      --extKeyUsage serverAuth \
      --extSAN "ip:$server_addr,dns:$server_addr" >/dev/null 2>&1 || exiterr "Не удалось создать сертификат сервера."
  fi
}

add_IKEv2_connection() {
  bigecho2 "Добавление нового соединения Cicada3301..."

  if ! grep -qs '^include /etc/ipsec\.d/\*\.conf$' /etc/ipsec.conf; then
    echo >> /etc/ipsec.conf
    echo 'include /etc/ipsec.d/*.conf' >> /etc/ipsec.conf
  fi

cat > /etc/ipsec.d/ikev2.conf <<EOF

conn ikev2-cp
  left=%defaultroute
  leftcert=$server_addr
  leftsendcert=always
  leftsubnet=0.0.0.0/0
  leftrsasigkey=%cert
  right=%any
  rightid=%fromcert
  rightaddresspool=192.168.43.10-192.168.43.250
  rightca=%same
  rightrsasigkey=%cert
  narrowing=yes
  dpddelay=30
  dpdtimeout=120
  dpdaction=clear
  auto=add
  ikev2=insist
  rekey=no
  pfs=no
  fragmentation=yes
  ike=aes256-sha2,aes128-sha2,aes256-sha1,aes128-sha1,aes256-sha2;modp1024,aes128-sha1;modp1024
  phase2alg=aes_gcm-null,aes128-sha1,aes256-sha1,aes128-sha2,aes256-sha2
  ikelifetime=24h
  salifetime=24h
  encapsulation=yes
EOF

  if [ "$use_dns_name" = "1" ]; then
cat >> /etc/ipsec.d/ikev2.conf <<EOF
  leftid=@$server_addr
EOF
  else
cat >> /etc/ipsec.d/ikev2.conf <<EOF
  leftid=$server_addr
EOF
  fi

  if [ -n "$dns_server_2" ]; then
cat >> /etc/ipsec.d/ikev2.conf <<EOF
  modecfgdns="$dns_servers"
EOF
  else
cat >> /etc/ipsec.d/ikev2.conf <<EOF
  modecfgdns=$dns_server_1
EOF
  fi

  if [ "$mobike_enable" = "1" ]; then
    echo "  mobike=yes" >> /etc/ipsec.d/ikev2.conf
  else
    echo "  mobike=no" >> /etc/ipsec.d/ikev2.conf
  fi
}

apply_ubuntu1804_nss_fix() {
  if [ "$os_type" = "ubuntu" ] && [ "$os_ver" = "bustersid" ] && [ "$os_arch" = "x86_64" ]; then
    nss_url1="https://mirrors.kernel.org/ubuntu/pool/main/n/nss"
    nss_url2="https://mirrors.kernel.org/ubuntu/pool/universe/n/nss"
    nss_deb1="libnss3_3.49.1-1ubuntu1.5_amd64.deb"
    nss_deb2="libnss3-dev_3.49.1-1ubuntu1.5_amd64.deb"
    nss_deb3="libnss3-tools_3.49.1-1ubuntu1.5_amd64.deb"
    TMPDIR=$(mktemp -d /tmp/nss.XXX 2>/dev/null)
    if [ -d "$TMPDIR" ]; then
      bigecho2 "Применение исправления для ошибки NSS в Ubuntu 18.04..."
      export DEBIAN_FRONTEND=noninteractive
      if wget -t 3 -T 30 -q -O "$TMPDIR/1.deb" "$nss_url1/$nss_deb1" \
        && wget -t 3 -T 30 -q -O "$TMPDIR/2.deb" "$nss_url1/$nss_deb2" \
        && wget -t 3 -T 30 -q -O "$TMPDIR/3.deb" "$nss_url2/$nss_deb3"; then
        apt-get -yqq update
        apt-get -yqq install "$TMPDIR/1.deb" "$TMPDIR/2.deb" "$TMPDIR/3.deb" >/dev/null
      fi
      /bin/rm -f "$TMPDIR/1.deb" "$TMPDIR/2.deb" "$TMPDIR/3.deb"
      /bin/rmdir "$TMPDIR"
    fi
  fi
}

restart_ipsec_service() {
  if [ "$in_container" = "0" ] || { [ "$in_container" = "1" ] && service ipsec status >/dev/null 2>&1; } then
    bigecho2 "Перезапуск службы IPsec..."

    mkdir -p /run/pluto
    service ipsec restart 2>/dev/null
  fi
}

print_client_added_message() {
cat <<EOF


================================================

Новый VPN-клиент Cicada3301 "$client_name" добавлен!

Адрес VPN-сервера: $server_addr
Имя клиента VPN: $client_name

EOF
}

print_client_exported_message() {
cat <<EOF


================================================

Клиент Cicada3301 "$client_name" экспортируется!

Адрес VPN-сервера: $server_addr
Имя клиента VPN: $client_name

EOF
}

show_swan_update_info() {
  if printf '%s' "$swan_ver_latest" | grep -Eq '^([3-9]|[1-9][0-9])\.([0-9]|[1-9][0-9])$' \
    && [ "$swan_ver" != "$swan_ver_latest" ] \
    && printf '%s\n%s' "$swan_ver" "$swan_ver_latest" | sort -C -V; then
    echo
    echo "Note: Более новая версия Libreswan ($swan_ver_latest)доступен."
    if [ "$in_container" = "0" ]; then
      get_update_url
      echo "      Для обновления запустите:"
      echo "      wget $update_url -O vpnupgrade.sh"
      echo "      sudo sh vpnupgrade.sh"
    else
      echo "      Чтобы обновить этот образ Docker, см.: https://git.io/updatedockervpn"
    fi
  fi
}
clear
print_setup_complete_message() {
  printf '\e[2K\r'
cat <<EOF

================================================

Настройка Cicada3301 прошла успешно. Подробная информация о режиме Cicada3301:

Адрес VPN-сервера: $server_addr
Имя клиента VPN: $client_name

EOF
}

print_client_info() {
  if [ "$in_container" = "0" ]; then
cat <<'EOF'
CДоступная конфигурация доступна по адресу:
EOF
  else
cat <<'EOF'
Конфигурация клиента доступна внутри
Контейнер Docker в:
EOF
  fi

cat <<EOF

$export_dir$client_name.p12 (for Windows & Linux)
$export_dir$client_name.sswan (for Android)
$export_dir$client_name.mobileconfig (for iOS & macOS)
EOF

  if [ "$use_own_password" = "0" ]; then
cat <<EOF

* ВАЖНО * Пароль для файлов конфигурации клиента:
$p12_password
Запишите это, оно вам понадобится для импорта!
EOF
  fi

cat <<'EOF'


================================================

EOF
}

check_ipsec_conf() {
 if grep -qs "conn ikev2-cp" /etc/ipsec.conf; then
    echo "Error: Раздел конфигурации IKEv2 находится в /etc/ipsec.conf." >&2
    echo "       Этот сценарий не может автоматически удалить Cicada3301 с этого сервера.." >&2
    echo "       Чтобы вручную удалить Cicada3301, см. https://git.io/Cicada3301" >&2
    echo "Прервать. Никаких изменений не было." >&2
    exit 1
  fi
}

confirm_remove_IKEv2() {
  echo
  echo "ВНИМАНИЕ! Эта опция удалит Cicada3301 с этого VPN-сервера, но сохранит IPsec / L2TP."
  echo "         а также IPsec/XAuth (\"Cisco IPsec\")режимы, если установлены. Вся конфигурация Cicada3301"
  echo "         включая сертификаты и ключи будут безвозвратно удалены."
  echo "         Это не может быть отменено! "
  echo
  printf "Вы уверены, что хотите удалить Cicada3301? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      echo
      ;;
    *)
      echo "Прервать. Никаких изменений не было."
      exit 1
      ;;
  esac
}

delete_IKEv2_conf() {
  bigecho "Deleting /etc/ipsec.d/ikev2.conf..."
  /bin/rm -f /etc/ipsec.d/ikev2.conf
}

delete_certificates() {
  echo
  bigecho "Удаление сертификатов и ключей из базы данных IPsec..."
  certutil -L -d sql:/etc/ipsec.d | grep -v -e '^$' -e 'IKEv2 VPN CA' | tail -n +3 | cut -f1 -d ' ' | while read -r line; do
    certutil -F -d sql:/etc/ipsec.d -n "$line"
    certutil -D -d sql:/etc/ipsec.d -n "$line" 2>/dev/null
  done
  certutil -F -d sql:/etc/ipsec.d -n "IKEv2 VPN CA"
  certutil -D -d sql:/etc/ipsec.d -n "IKEv2 VPN CA" 2>/dev/null
}

print_IKEv2_removed_message() {
  echo
  echo "IKEv2 удален!"
}

IKEv2setup() {
  check_run_as_root
  check_os_type
  check_swan_install
  check_utils_exist
  check_container

  use_defaults=0
  add_client_using_defaults=0
  export_client_using_defaults=0
  list_clients=0
  remove_IKEv2=0
  while [ "$#" -gt 0 ]; do
    case $1 in
      --auto)
        use_defaults=1
        shift
        ;;
      --addclient)
        add_client_using_defaults=1
        client_name="$2"
        shift
        shift
        ;;
      --exportclient)
        export_client_using_defaults=1
        client_name="$2"
        shift
        shift
        ;;
      --listclients)
        list_clients=1
        shift
        ;;
      --removeIKEv2)
        remove_IKEv2=1
        shift
        ;;
      -h|--help)
        show_usage
        ;;
      *)
        show_usage "Неизвестный параметр: $1"
        ;;
    esac
  done

  check_arguments
  get_export_dir

  if [ "$add_client_using_defaults" = "1" ]; then
    show_add_client_message
    client_validity=120
    use_own_password=0
    create_client_cert
    install_base64_uuidgen
    export_p12_file
    create_mobileconfig
    create_android_profile
    print_client_added_message
    print_client_info
    exit 0
  fi

  if [ "$export_client_using_defaults" = "1" ]; then
    show_export_client_message
    use_own_password=0
    install_base64_uuidgen
    export_p12_file
    create_mobileconfig
    create_android_profile
    print_client_exported_message
    print_client_info
    exit 0
  fi

  if [ "$list_clients" = "1" ]; then
    list_existing_clients
    exit 0
  fi

  if [ "$remove_IKEv2" = "1" ]; then
    check_ipsec_conf
    confirm_remove_IKEv2
    delete_IKEv2_conf
    restart_ipsec_service
    delete_certificates
    print_IKEv2_removed_message
    exit 0
  fi

  if check_IKEv2_exists; then
    select_menu_option
    case $selected_option in
      1)
        enter_client_name
        enter_client_cert_validity
        select_p12_password
        create_client_cert
        install_base64_uuidgen
        export_p12_file
        create_mobileconfig
        create_android_profile
        print_client_added_message
        print_client_info
        exit 0
        ;;
      2)
        enter_client_name_for_export
        select_p12_password
        install_base64_uuidgen
        export_p12_file
        create_mobileconfig
        create_android_profile
        print_client_exported_message
        print_client_info
        exit 0
        ;;
      3)
        echo
        list_existing_clients
        exit 0
        ;;
      4)
        check_ipsec_conf
        confirm_remove_IKEv2
        delete_IKEv2_conf
        restart_ipsec_service
        delete_certificates
        print_IKEv2_removed_message
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
  fi

  check_ca_cert_exists
  check_swan_ver

  if [ "$use_defaults" = "0" ]; then
    select_swan_update
    show_welcome_message
    enter_server_address
    check_server_cert_exists
    enter_client_name_with_defaults
    enter_client_cert_validity
    enter_custom_dns
    check_mobike_support
    select_mobike
    select_p12_password
    confirm_setup_options
  else
    check_server_dns_name
    check_custom_dns
    if [ -n "$VPN_CLIENT_NAME" ]; then
      client_name="$VPN_CLIENT_NAME"
      check_client_name || exiterr "Неверное имя клиента. Используйте только одно слово, никаких специальных символов, кроме '-' а также '_'."
    else
      client_name=vpnclient
    fi
    check_client_cert_exists && exiterr "Client '$client_name' уже существует."
    client_validity=120
    show_start_message
    if [ -n "$VPN_DNS_NAME" ]; then
      use_dns_name=1
      server_addr="$VPN_DNS_NAME"
    else
      use_dns_name=0
      get_server_ip
      check_ip "$public_ip" || exiterr "Не удается определить общедоступный IP-адрес этого сервера."
      server_addr="$public_ip"
    fi
    check_server_cert_exists
    if [ -n "$VPN_DNS_SRV1" ] && [ -n "$VPN_DNS_SRV2" ]; then
      dns_server_1="$VPN_DNS_SRV1"
      dns_server_2="$VPN_DNS_SRV2"
      dns_servers="$VPN_DNS_SRV1 $VPN_DNS_SRV2"
    elif [ -n "$VPN_DNS_SRV1" ]; then
      dns_server_1="$VPN_DNS_SRV1"
      dns_server_2=""
      dns_servers="$VPN_DNS_SRV1"
    else
      dns_server_1=8.8.8.8
      dns_server_2=8.8.4.4
      dns_servers="8.8.8.8 8.8.4.4"
    fi
    check_mobike_support
    mobike_enable="$mobike_support"
    use_own_password=0
  fi

  apply_ubuntu1804_nss_fix
  create_ca_server_certs
  create_client_cert
  install_base64_uuidgen
  export_p12_file
  create_mobileconfig
  create_android_profile
  add_IKEv2_connection
  restart_ipsec_service

  if [ "$use_defaults" = "1" ]; then
    show_swan_update_info
  fi

  print_setup_complete_message
  print_client_info
}

## Отложите настройку, пока у нас не будет полного сценария
IKEv2setup "$@"

exit 0
