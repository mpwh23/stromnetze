package config

import "os"

type Config struct {
	Addr           string
	PublicBasePath string
	DatabaseURL    string
}

func Load() Config {
	return Config{
		Addr:           getEnv("STROM_ADDR", "127.0.0.1:8088"),
		PublicBasePath: getEnv("STROM_PUBLIC_BASE_PATH", "/strom"),
		DatabaseURL:    getEnv("DATABASE_URL", "postgres://strom_app:change_me@127.0.0.1:5432/strom?sslmode=disable"),
	}
}

func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
