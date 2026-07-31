package main

import (
	"bufio"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"

	"golang.org/x/term"

	"github.com/Liafanx/mtproxyl-panel/internal/auth"
	"github.com/Liafanx/mtproxyl-panel/internal/config"
	"github.com/Liafanx/mtproxyl-panel/internal/server"
)

var version = "0.1.0"

func main() {
	if len(os.Args) > 1 && os.Args[1] == "version" {
		fmt.Println("mtproxyl-panel " + version)
		return
	}

	if len(os.Args) > 1 && os.Args[1] == "hash-password" {
		var password string
		if term.IsTerminal(int(os.Stdin.Fd())) {
			fmt.Print("Enter password: ")
			passwordBytes, err := term.ReadPassword(int(os.Stdin.Fd()))
			fmt.Println()
			if err != nil {
				log.Fatalf("Failed to read password: %v", err)
			}
			password = string(passwordBytes)
		} else {
			scanner := bufio.NewScanner(os.Stdin)
			if scanner.Scan() {
				password = strings.TrimSpace(scanner.Text())
			}
			if password == "" {
				log.Fatal("No password provided on stdin")
			}
		}
		hash, err := auth.HashPassword(password)
		if err != nil {
			log.Fatalf("Failed to hash password: %v", err)
		}
		fmt.Println(hash)
		return
	}

	configPath := flag.String("config", "config.toml", "path to config file")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	srv := server.New(cfg)
	log.Fatal(srv.Run(version, distFS))
}
