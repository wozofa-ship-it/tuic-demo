package libbox

import (
	"errors"

	sbox "github.com/sagernet/sing-box/experimental/libbox"
)

// demoHandler implements libbox.CommandServerHandler in Go so Swift never
// has to. Method set verified against sing-box v1.14.4
// experimental/libbox/command_server.go (CommandServerHandler interface).
type demoHandler struct{}

func (h *demoHandler) ServiceStop() error { return nil }

func (h *demoHandler) ServiceReload() error { return nil }

// The demo never touches the system proxy, so report it as unavailable.
func (h *demoHandler) GetSystemProxyStatus() (*sbox.SystemProxyStatus, error) {
	return &sbox.SystemProxyStatus{Available: false, Enabled: false}, nil
}

func (h *demoHandler) SetSystemProxyEnabled(enabled bool) error { return nil }

func (h *demoHandler) TriggerNativeCrash() error { return nil }

func (h *demoHandler) WriteDebugMessage(message string) {}

func (h *demoHandler) ConnectSSHAgent() (int32, error) {
	return 0, errors.New("ssh agent not supported in demo")
}
