package libbox

import (
	"errors"

	sbox "github.com/sagernet/sing-box/experimental/libbox"
)

// minimalPlatform implements libbox.PlatformInterface entirely in Go.
//
// The demo config has NO tun inbound, so the platform methods that matter
// for real VPN apps (OpenTun, interface monitor, shell, bridge) are stubs.
// Methods that the core may call for a SOCKS-only config return safe
// empty values:
//
//   - UsePlatformAutoDetectInterfaceControl: false, so the core does not
//     ask us to bind sockets to a specific interface.
//   - GetInterfaces: empty iterator (no interfaces reported).
//   - UnderNetworkExtension: false (this is a plain in-app process, not a
//     NetworkExtension, and the demo requests NO entitlements).
//   - LocalDNSTransport: nil. LocalDNSTransport is an interface type
//     (experimental/libbox/dns.go), so nil is a valid return; baseContext
//     only registers the local transport when it is non-nil
//     (experimental/libbox/config.go).
//
// Method set verified against sing-box v1.14.4
// experimental/libbox/platform.go (PlatformInterface interface).
type minimalPlatform struct{}

var _ sbox.PlatformInterface = (*minimalPlatform)(nil)

func (p *minimalPlatform) LocalDNSTransport() sbox.LocalDNSTransport { return nil }

func (p *minimalPlatform) UsePlatformAutoDetectInterfaceControl() bool { return false }

func (p *minimalPlatform) AutoDetectInterfaceControl(fd int32) error { return nil }

func (p *minimalPlatform) OpenTun(options sbox.TunOptions) (int32, error) {
	return 0, errors.New("tun not supported in demo")
}

func (p *minimalPlatform) FindConnectionOwner(ipProtocol int32, sourceAddress string, sourcePort int32, destinationAddress string, destinationPort int32) (*sbox.ConnectionOwner, error) {
	return nil, errors.New("connection owner lookup not supported in demo")
}

func (p *minimalPlatform) StartDefaultInterfaceMonitor(listener sbox.InterfaceUpdateListener) error {
	return nil
}

func (p *minimalPlatform) CloseDefaultInterfaceMonitor(listener sbox.InterfaceUpdateListener) error {
	return nil
}

func (p *minimalPlatform) GetInterfaces() (sbox.NetworkInterfaceIterator, error) {
	return &emptyInterfaceIterator{}, nil
}

func (p *minimalPlatform) UnderNetworkExtension() bool { return false }

func (p *minimalPlatform) IncludeAllNetworks() bool { return false }

func (p *minimalPlatform) ReadWIFIState() *sbox.WIFIState { return nil }

func (p *minimalPlatform) ClearDNSCache() {}

func (p *minimalPlatform) SendNotification(notification *sbox.Notification) error { return nil }

func (p *minimalPlatform) CancelNotification(identifier string, typeID int32) error {
	return nil
}

func (p *minimalPlatform) StartNeighborMonitor(listener sbox.NeighborUpdateListener) error {
	return nil
}

func (p *minimalPlatform) CloseNeighborMonitor(listener sbox.NeighborUpdateListener) error {
	return nil
}

func (p *minimalPlatform) RegisterMyInterface(name string) {}

func (p *minimalPlatform) UsePlatformShell() bool { return false }

func (p *minimalPlatform) CheckPlatformShell() error { return nil }

func (p *minimalPlatform) OpenShellSession(user *sbox.PlatformUser, command string, environ sbox.StringIterator, term string, rows int32, cols int32) (sbox.ShellSession, error) {
	return nil, errors.New("shell not supported in demo")
}

func (p *minimalPlatform) LookupUser(username string) (*sbox.PlatformUser, error) {
	return nil, errors.New("user lookup not supported in demo")
}

func (p *minimalPlatform) LookupSFTPServer() (string, error) {
	return "", errors.New("sftp not supported in demo")
}

func (p *minimalPlatform) ReadSystemSSHHostKey() (string, error) {
	return "", errors.New("ssh host key not supported in demo")
}

func (p *minimalPlatform) TailscaleHostname() string { return "" }

func (p *minimalPlatform) UsePlatformBridge() bool { return false }

func (p *minimalPlatform) CreateBridge(options *sbox.BridgeOptions) (sbox.BridgeSession, error) {
	return nil, errors.New("bridge not supported in demo")
}

// emptyInterfaceIterator implements sbox.NetworkInterfaceIterator with zero
// interfaces. Method set verified against
// experimental/libbox/platform.go (NetworkInterfaceIterator interface).
type emptyInterfaceIterator struct{}

func (e *emptyInterfaceIterator) Next() *sbox.NetworkInterface { return nil }

func (e *emptyInterfaceIterator) HasNext() bool { return false }
