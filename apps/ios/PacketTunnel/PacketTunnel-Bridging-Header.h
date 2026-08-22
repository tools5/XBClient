// PacketTunnel 的 Swift↔C 桥接头。
// iOS Darwin 模块默认不向 Swift 暴露 kern_control 的 sockaddr_ctl/ctl_info，
// CTLIOCGINFO 又是 _IOWR 函数式宏（Swift 无法导入）。桥接头在 Swift target 的完整
// sysroot 上下文里编译，能可靠找到这些系统头，并把宏在 C 侧求值成常量供 Swift 使用。
#ifndef AERION_PACKETTUNNEL_BRIDGING_H
#define AERION_PACKETTUNNEL_BRIDGING_H

#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/sys_domain.h>

static const unsigned long AERION_CTLIOCGINFO = CTLIOCGINFO;

#endif /* AERION_PACKETTUNNEL_BRIDGING_H */
