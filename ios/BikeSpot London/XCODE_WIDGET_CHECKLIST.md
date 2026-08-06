# Xcode Widget Configuration Checklist

Quick reference checklist for configuring the widget extension in Xcode.

## ✅ Pre-Configuration

- [ ] All widget files are created in `/BikeSpot London Widget/` folder
- [ ] All shared model files are created
- [ ] WidgetService is created in main app

## ✅ Step 1: Create Widget Extension Target

- [ ] File → New → Target → Widget Extension
- [ ] Product Name: `BikeSpot London Widget`
- [ ] Bundle ID: `dev.skynolimit.myborisbikes.widget`
- [ ] Click "Activate" when prompted
- [ ] Delete auto-generated widget files from Xcode

## ✅ Step 2: Add Files to Widget Target

Add these files to widget target membership (check box in File Inspector):

### Widget Extension Files (all in `BikeSpot London Widget/` folder)
- [ ] `BikeSpot_London_Widget.swift`
- [ ] `Views/SmallWidgetView.swift`
- [ ] `Views/MediumWidgetView.swift`
- [ ] `Views/LargeWidgetView.swift`
- [ ] `Components/WidgetDockRow.swift`
- [ ] `Components/WidgetDonutChart.swift`
- [ ] `Components/EmptyWidgetView.swift`
- [ ] `Info.plist`
- [ ] `BikeSpot_London_Widget.entitlements`
- [ ] `Assets.xcassets/`

### Shared Files (also add to widget target)
- [ ] `BikeSpot London/Models/WidgetModels.swift`
- [ ] `BikeSpot London/Models/BikePoint.swift`
- [ ] `BikeSpot London/Configuration/AppConstants.swift`

## ✅ Step 3: Configure App Group

### For Widget Target
- [ ] Select "BikeSpot London Widget" target
- [ ] Go to "Signing & Capabilities"
- [ ] Add capability: "App Groups"
- [ ] Enable: `group.dev.skynolimit.myborisbikes`

### Verify Main App
- [ ] Select "BikeSpot London" target
- [ ] Verify "App Groups" capability exists
- [ ] Verify `group.dev.skynolimit.myborisbikes` is enabled

## ✅ Step 4: Configure URL Scheme

- [ ] Select "BikeSpot London" (main app) target
- [ ] Go to "Info" tab
- [ ] Scroll to "URL Types" section
- [ ] Click "+" to add new URL type
- [ ] Set Identifier: `dev.skynolimit.myborisbikes`
- [ ] Set URL Schemes: `myborisbikes`
- [ ] Set Role: `Editor`

## ✅ Step 5: Build Settings

### Widget Target Settings
- [ ] Select "BikeSpot London Widget" target
- [ ] Go to "Build Settings"
- [ ] Set "iOS Deployment Target": **18.5**
- [ ] Set "Swift Language Version": **Swift 5**

### Main App Settings (verify)
- [ ] Select "BikeSpot London" target
- [ ] Verify "iOS Deployment Target": **18.5**
- [ ] Verify "Swift Language Version": **Swift 5**

## ✅ Step 6: Code Signing

### Main App Target
- [ ] Select "BikeSpot London" target
- [ ] Go to "Signing & Capabilities"
- [ ] Ensure "Automatically manage signing" is checked
- [ ] Select your Development Team

### Widget Target
- [ ] Select "BikeSpot London Widget" target
- [ ] Go to "Signing & Capabilities"
- [ ] Ensure "Automatically manage signing" is checked
- [ ] Select your Development Team (same as main app)

## ✅ Step 7: Entitlements Files

### Main App
- [ ] File exists: `BikeSpot London/BikeSpot London.entitlements`
- [ ] Contains: `com.apple.security.application-groups` with `group.dev.skynolimit.myborisbikes`
- [ ] Build Settings → Code Signing Entitlements points to this file

### Widget Extension
- [ ] File exists: `BikeSpot London Widget/BikeSpot_London_Widget.entitlements`
- [ ] Contains: `com.apple.security.application-groups` with `group.dev.skynolimit.myborisbikes`
- [ ] Build Settings → Code Signing Entitlements points to this file

## ✅ Step 8: Verify Scheme Configuration

- [ ] "BikeSpot London" scheme exists (for main app development)
- [ ] "BikeSpot London Widget" scheme exists (for widget debugging)
- [ ] Both schemes build successfully

## ✅ Final Verification

### Build Test
- [ ] Clean Build Folder (Cmd+Shift+K)
- [ ] Build "BikeSpot London" scheme - succeeds without errors
- [ ] Build "BikeSpot London Widget" scheme - succeeds without errors

### File Structure Check
```
BikeSpot London/
├── Models/
│   ├── WidgetModels.swift ✓ (shared with widget)
│   └── BikePoint.swift ✓ (shared with widget)
├── Services/
│   └── WidgetService.swift ✓ (main app only)
├── Configuration/
│   └── AppConstants.swift ✓ (shared with widget)
└── BikeSpot London.entitlements ✓

BikeSpot London Widget/
├── BikeSpot_London_Widget.swift ✓
├── Views/
│   ├── SmallWidgetView.swift ✓
│   ├── MediumWidgetView.swift ✓
│   └── LargeWidgetView.swift ✓
├── Components/
│   ├── WidgetDockRow.swift ✓
│   ├── WidgetDonutChart.swift ✓
│   └── EmptyWidgetView.swift ✓
├── Info.plist ✓
├── BikeSpot_London_Widget.entitlements ✓
└── Assets.xcassets/ ✓
```

## ✅ Testing Checklist

### In Simulator
- [ ] Run main app, add 3-5 favorites
- [ ] Stop app
- [ ] Long-press home screen → Add Widget
- [ ] Find "BikeSpot London" in widget gallery
- [ ] Add Small widget - shows first favorite with initials
- [ ] Add Medium widget - shows 2 favorites with details
- [ ] Add Large widget - shows up to 5 favorites
- [ ] Run app again, modify favorites
- [ ] Widgets update within a few seconds
- [ ] Tap widget - app opens to Favorites screen

### Data Flow Test
- [ ] Add a favorite in app → Widget shows new favorite
- [ ] Remove a favorite → Widget updates to remove it
- [ ] Change sort mode → Widget respects sort order
- [ ] Enable location → Widget shows distances
- [ ] Pull to refresh app → Widget data updates

### Deep Linking Test
- [ ] Tap small widget → Opens app to specific dock
- [ ] Tap medium/large widget → Opens app to Favorites tab

## 🐛 Common Issues

### Widget not showing in gallery
- ➡️ Rebuild widget target
- ➡️ Check target membership of widget files
- ➡️ Verify bundle identifier is correct

### Widget shows empty state despite having favorites
- ➡️ Check app group entitlement on both targets
- ➡️ Verify `ios_widget_data` key in UserDefaults
- ➡️ Add print statements in WidgetService.saveWidgetData()

### Widget not updating
- ➡️ Check WidgetCenter.reloadAllTimelines() is called
- ➡️ Verify HomeViewModel.updateWidgetData() is called
- ➡️ Check timeline refresh policy (should be 5 minutes)

### Build errors
- ➡️ Clean build folder (Cmd+Shift+K)
- ➡️ Check Swift version consistency
- ➡️ Verify target memberships of shared files

### Deep linking not working
- ➡️ Verify URL scheme in Info.plist
- ➡️ Check onOpenURL handler in BikeSpot_LondonApp.swift
- ➡️ Test URL: `myborisbikes://favorites`

## 📝 Notes

- Widget updates occur every 5 minutes automatically
- Manual updates trigger via WidgetCenter when favorites change
- App group UserDefaults key: `ios_widget_data`
- Supported sizes: Small, Medium, Large (not Extra Large)
- Minimum iOS version: 18.5

## ✅ Done!

Once all checkboxes are complete:
1. Build and run the app
2. Add some favorites
3. Add widgets to home screen
4. Enjoy your BikeSpot London widgets!

---

**Questions?** Refer to `WIDGET_SETUP.md` for detailed explanations.
