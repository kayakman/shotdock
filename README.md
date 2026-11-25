# ShotDock

App para macOS para hacer y gestionar capturas de pantalla, con todo lo que hace Shottr.

## Requisitos

- macOS 15 o posterior, Xcode 16+ (probado con Xcode 27.2 en macOS 27).

## Compilar y ejecutar

```sh
make signing-cert   # una vez por Mac: identidad local "ShotDock Local Signing"
make test           # tests de ShotDockCore
make run            # monta build/ShotDock.app, la firma y la abre
make selftest       # captura la pantalla sin interacción y comprueba el PNG
```

La firma local estable hace que macOS conserve el permiso de Grabación de
pantalla entre compilaciones. La primera vez hay que concederlo en
Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla.

## Estructura

- `Sources/ShotDockCore`: lógica sin interfaz (imágenes, anotaciones, historial, subida…), con tests.
- `Sources/ShotDock`: la app de barra de menús (AppKit + SwiftUI, ScreenCaptureKit, Vision).
- `Resources/Info.plist`: plist del bundle (`app.shotdock.ShotDock`).
