# OpenWrt 江南大学 CMCC-EDU 自动登录脚本

用于江南大学/CMCC-EDU 类门户的自动登录，运行于 OpenWrt。

参考[CMCC-Campus-Login](https://github.com/Sorkai/CMCC-Campus-Login) ，[CMCC-Campus-Auto-Auth](https://github.com/Afool4U/CMCC-Campus-Auto-Auth)


## 依赖
- curl（必需），logger（建议）
```sh
opkg update && opkg install curl
```

## 快速开始
```sh
export IFACE='YOUR_IFACE'          # 例如 phy0-sta1
export USERNAME='你的账号'
export PASSWORD='你的密码'
sh auto_login.sh
```

## 定时任务（可选）
```sh
crontab -e
*/2 * * * * IFACE=YOUR_IFACE USERNAME='你的账号' PASSWORD='你的密码' sh /test_auto_login.sh >/dev/null 2>&1
```
