// Package libbox is a minimal gomobile-friendly wrapper around upstream
// sing-box experimental/libbox.
//
// Why a wrapper: gomobile bind can only expose a limited set of Go types to
// Swift (strings, numbers, errors). libbox's own API takes structs and
// interfaces (SetupOptions, PlatformInterface, CommandServerHandler), which
// must NOT leak into the Swift boundary. This package implements the whole
// platform side in Go and exposes only string/error functions to Swift.
//
// Upstream API references (sing-box v1.14.4, verified against source):
//   - libbox.Setup(options *SetupOptions) error
//     experimental/libbox/setup.go
//   - libbox.CheckConfig(configContent string) error
//     experimental/libbox/config.go
//   - libbox.NewCommandServer(handler CommandServerHandler,
//     platformInterface PlatformInterface) (*CommandServer, error)
//     experimental/libbox/command_server.go
//   - (*CommandServer).Start() error,
//     (*CommandServer).StartOrReloadService(configContent string,
//     options *OverrideOptions) error,
//     (*CommandServer).CloseService() error, (*CommandServer).Close()
//     experimental/libbox/command_server.go
//   - libbox.Version() string, experimental/libbox/setup.go
//
// IMPORTANT: v1.14.4 does NOT have the old BoxService/NewService API anymore
// (that was removed in the command-system refactor). Anyone "remembering"
// libbox.NewService from older versions is remembering a stale API.
package libbox

import (
	"errors"

	sbox "github.com/sagernet/sing-box/experimental/libbox"
)

var commandServer *sbox.CommandServer

// Setup initializes libbox process-wide state. It must be called once before
// any other function. basePath is Documents root (NOT Documents/singbox):
// libbox binds its command server at basePath + "/command.sock", and
// Darwin AF_UNIX sun_path caps at 104 bytes; the app container prefix
// alone is 76 bytes, so Documents/singbox would make 107 and bind fails
// EINVAL on device. workingPath/tempPath are Documents/singbox.
func Setup(basePath, workingPath, tempPath string) error {
	return sbox.Setup(&sbox.SetupOptions{
		BasePath:    basePath,
		WorkingPath: workingPath,
		TempPath:    tempPath,
	})
}

// CheckConfig validates a sing-box JSON config without starting anything.
// Use it before StartService so a JSON/field error surfaces as a config
// error, not as a mysterious start failure.
func CheckConfig(configJSON string) error {
	return sbox.CheckConfig(configJSON)
}

// StartService starts the core with the given sing-box JSON config.
// Only one service runs at a time; call StopService first to restart.
func StartService(configJSON string) error {
	if commandServer != nil {
		return errors.New("service already started, stop it first")
	}
	server, err := sbox.NewCommandServer(&demoHandler{}, &minimalPlatform{})
	if err != nil {
		return err
	}
	if err := server.Start(); err != nil {
		server.Close()
		return err
	}
	// Empty OverrideOptions: nil iterators are safe, iteratorToArray(nil)
	// returns nil (experimental/libbox/iterator.go).
	if err := server.StartOrReloadService(configJSON, &sbox.OverrideOptions{}); err != nil {
		server.Close()
		return err
	}
	commandServer = server
	return nil
}

// StopService stops the running service and frees the command server.
func StopService() error {
	if commandServer == nil {
		return errors.New("service not started")
	}
	err := commandServer.CloseService()
	commandServer.Close()
	commandServer = nil
	return err
}

// Version returns the sing-box version string (e.g. "1.14.4").
func Version() string {
	return sbox.Version()
}
