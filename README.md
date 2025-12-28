#  Photo Uploader for Immich (iOS)

This was an attempt at using the new [iOS PhotoKit Background Resource Upload extension type](https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background). Unfortunately due to limitations of the implementation by Apple this cannot be used though:

1. Apple forces the developer to hardcode the URL that the photos will be uploaded to "for network access validation" (`BackgroundUploadURLBase` has to be added to the `Info.plist` file). This means it's impossible to use the PhotoKit upload with a User-configurable URL which would be necessary for using it with systems like Immich (since every Immich instance has their own URL).
2. I then tried implementing this just for my own instance, but the [Immich API for uploading assets](https://api.immich.app/endpoints/assets/uploadAsset) has some required fields like `deviceAssetId`, `deviceId` etc. These have to be sent to Immich as `multipart/form-data`. This is currently not supported by the PhotoKit upload, as the body of the HTTP request can only contain the asset itself.

