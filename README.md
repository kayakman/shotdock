<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="design/logo-blanco.png">
    <img src="design/logo-transparente.png" alt="ShotDock" width="420">
  </picture>
</p>

# ShotDock

App para macOS para hacer y gestionar capturas de pantalla, con todo lo que hace Shottr.

## Qué hace

- **Capturas**: área (sobre la pantalla congelada, con lupa), ventana (elegirla o la activa),
  pantalla completa, repetir la última área, con retardo y con scroll.
- **Editor**: flecha, rectángulo, óvalo, texto, resaltador, pasos numerados, desenfocar,
  pixelar, borrador inteligente (rellena con el fondo, también degradados), recortar,
  tiradores para redimensionar, deshacer.
- **Medir**: regla de píxeles entre bordes, lupa y cuentagotas (HEX/RGB), también global.
- **OCR y QR** con Vision: el atajo copia el texto (o el contenido del QR) del área.
- **Fijar** capturas encima de todo, con zoom, opacidad y clics que la atraviesan.
- **Fondos y marcos** para compartir: degradados, margen, esquinas, sombra y proporción.
- **Subida a S3** (AWS, Cloudflare R2, Backblaze B2, MinIO…) con el enlace copiado;
  claves en el llavero.
- **El dock**: historial de capturas con sus anotaciones editables, galería para reabrir,
  copiar, guardar, subir, fijar o arrastrar a otra app.
- Barra de menús, atajos globales configurables (se importan los de Shottr), preferencias,
  nombre y carpeta de guardado configurables, abrir al iniciar sesión.

## Requisitos

- macOS 15 o posterior, Xcode 16+ (probado con Xcode 27.2 en macOS 27).

## Compilar y ejecutar

```sh
make signing-cert     # una vez por Mac: identidad local "ShotDock Local Signing"
make test             # tests de ShotDockCore
make run              # monta build/ShotDock.app, la firma y la abre
make install          # versión release en /Applications
make selftest TEST=…  # pruebas en la app real: capture, area, editor, modes, prefs, measure,
                      # history, pin-ocr, backdrop, scroll, dock, branding
make selftest-upload  # subida contra un S3 local (scripts/mock-s3.py)
```

La firma local estable hace que macOS conserve el permiso de Grabación de
pantalla entre compilaciones. La primera vez hay que concederlo en
Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla. La captura
con scroll automática necesita además el permiso de Accesibilidad.

Las pruebas `selftest` manejan la app con eventos simulados, usan unas preferencias,
un historial y un llavero propios, y no tocan los del usuario.

## Estructura

- `Sources/ShotDockCore`: lógica sin interfaz (anotaciones y su dibujo, efectos, borrador
  inteligente, regla, OCR, unión de capturas con scroll, fondos, historial, firma S3,
  importación de Shottr), con tests.
- `Sources/ShotDock`: la app de barra de menús (AppKit + SwiftUI, ScreenCaptureKit, Vision).
- `Resources/Info.plist`: plist del bundle (`app.shotdock.ShotDock`).
- `Resources/Assets.xcassets`: AppIcon, icono de la barra de menús, logo y color de acento (#FF5A1F).
- `design/`: diseño aprobado (`icono.png`, `logo.png`) y sus fuentes vectoriales. `make icons`
  regenera los iconos desde `design/make-icons.swift`; `swift design/make-logo.swift` las
  versiones del logo con fondo transparente y en blanco.
