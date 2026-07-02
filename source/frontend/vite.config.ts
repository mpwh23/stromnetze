import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

const base = process.env.VITE_BASE || '/strom/'

export default defineConfig({
  base,
  plugins: [react()],
})
