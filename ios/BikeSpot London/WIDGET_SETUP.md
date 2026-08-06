# iOS Widget Setup Instructions

This document describes the iOS home screen widget implementation for "BikeSpot London" and the required Xcode configuration steps.

## Overview

The widget extension provides users with quick access to their favorite bike docks directly from the iOS home screen. The widget supports three sizes:

- **Small Widget**: Shows the closest favorite dock with initials, donut chart, total bikes count, and distance
- **Medium Widget**: Shows up to 2 favorite docks with full details (name, donut chart, bike/e-bike/space counts, distance)
- **Large Widget**: Shows up to 5 favorite docks with full details

All widgets update automatically every 5 minutes and support sorting by distance (default), alphabetical, or manual order.

## Widget Features

### Data Display
- **Donut charts** showing bike availability breakdown (standard bikes, e-bikes, empty spaces)
- **Visual distance indicators** with color-coded bars matching the main app design
  - Shows distances in meters (m) for < 1km, miles for longer distances
  - Color-coded: green (very close), mint (close), orange (moderate), purple (far), red (very far)
- **Real-time data** synced from the main app
- **Sort mode indicator** (location icon for distance-based sorting)

### User Interaction
- Tapping a widget opens the app to the Favorites screen
- Small widgets link directly to the specific dock shown
- Empty state with helpful message when no favorites exist

### Data Synchronization
- Widget data is shared via App Group (`group.dev.skynolimit.myborisbikes`)
- Updates triggered automatically when favorites change
- Updates triggered on app data refresh (every 30 seconds)
- Manual refresh via pull-to-refresh in the app

## Files Created

### Models
- `BikeSpot London/Models/WidgetModels.swift` - Data models for widget communication
  - `WidgetBikePointData` - Optimized bike point data for widgets
  - `WidgetData` - Container for all widget data
  - `WidgetFavorite` - Simple favorite representation

### Services
- `BikeSpot London/Services/WidgetService.swift` - Widget data management service
  - Updates widget data from app
  - Handles sorting (distance, alphabetical, manual)
  - Triggers widget timeline reloads

### Widget Extension Files
- `BikeSpot London Widget/BikeSpot_London_Widget.swift` - Main widget entry point and timeline provider
- `BikeSpot London Widget/Views/SmallWidgetView.swift` - Small widget layout
- `BikeSpot London Widget/Views/MediumWidgetView.swift` - Medium widget layout
- `BikeSpot London Widget/Views/LargeWidgetView.swift` - Large widget layout
- `BikeSpot London Widget/Components/WidgetDockRow.swift` - Reusable dock row component
- `BikeSpot London Widget/Components/WidgetDonutChart.swift` - Widget-optimized donut chart
- `BikeSpot London Widget/Components/EmptyWidgetView.swift` - Empty state view
- `BikeSpot London Widget/Info.plist` - Widget extension configuration
- `BikeSpot London Widget/BikeSpot_London_Widget.entitlements` - Widget entitlements (app group)
- `BikeSpot London Widget/Assets.xcassets/` - Widget asset catalog

## Modified Files

### App Files
- `BikeSpot_LondonApp.swift` - Added deep linking support for widget taps
- `ContentView.swift` - Added support for deep link navigation
- `ViewModels/HomeViewModel.swift` - Integrated WidgetService for data updates
- `Services/FavoritesService.swift` - Added widget timeline reload triggers

## Xcode Configuration Required

### Step 1: Create Widget Extension Target

1. **Add New Target**
   - In Xcode, go to: File → New → Target
   - Select "Widget Extension"
   - Product Name: `BikeSpot London Widget`
   - Bundle Identifier: `dev.skynolimit.myborisbikes.widget`
   - Click "Finish"
   - When prompted "Activate scheme?", click "Activate"

2. **Delete Auto-Generated Files**
   - Delete the auto-generated widget files that Xcode creates
   - We'll use the files created in this implementation instead

### Step 2: Add Files to Widget Target

1. **Add Widget Extension Files**
   - Select all files in `BikeSpot London Widget/` folder
   - In File Inspector (right panel), check the box for "BikeSpot London Widget" target membership

2. **Add Shared Files to Widget Target**
   The widget needs access to these app files. For each file below, select it and check the "BikeSpot London Widget" target membership in File Inspector:

   - `Models/WidgetModels.swift` ✓
   - `Models/BikePoint.swift` ✓
   - `Configuration/AppConstants.swift` ✓

   Note: The widget extension will compile its own version of these shared files.

### Step 3: Configure App Group Entitlement

The app group should already exist, but you need to add it to the widget target:

1. **Select Widget Target**
   - In Xcode project navigator, select the project
   - Select "BikeSpot London Widget" target
   - Go to "Signing & Capabilities" tab

2. **Add App Group Capability**
   - Click "+ Capability" button
   - Add "App Groups"
   - Enable the existing app group: `group.dev.skynolimit.myborisbikes`

3. **Verify Entitlements File**
   - Ensure `BikeSpot_London_Widget.entitlements` is set as the entitlements file
   - Should be automatically configured, but verify in Build Settings → Code Signing Entitlements

### Step 4: Configure URL Scheme for Deep Linking

1. **Select Main App Target**
   - Select "BikeSpot London" target
   - Go to "Info" tab

2. **Add URL Type**
   - Scroll to "URL Types" section
   - Click "+" to add a new URL type
   - **Identifier**: `dev.skynolimit.myborisbikes`
   - **URL Schemes**: `myborisbikes`
   - **Role**: Editor

### Step 5: Configure Build Settings

1. **Widget Extension Deployment Target**
   - Select "BikeSpot London Widget" target
   - Go to "Build Settings"
   - Set "iOS Deployment Target" to **18.5** (to match main app)

2. **Swift Language Version**
   - Ensure "Swift Language Version" is set to **Swift 5**

### Step 6: Add Widget Assets (Optional)

You can customize the widget icon in the widget gallery:

1. **Widget Icon Asset**
   - Open `BikeSpot London Widget/Assets.xcassets`
   - Add an "App Icon" asset if you want a custom widget gallery icon
   - Otherwise, it will use the main app icon

### Step 7: Configure Schemes

1. **Edit Main App Scheme**
   - Product → Scheme → Edit Scheme
   - Ensure "BikeSpot London" is selected
   - This is the scheme you'll use for normal app development

2. **Widget Extension Scheme**
   - There should be a "BikeSpot London Widget" scheme created automatically
   - Use this scheme when you want to debug the widget specifically
   - Run this scheme to test widgets in the simulator

## Testing the Widget

### In Simulator

1. **Build and Run Main App**
   - Select "BikeSpot London" scheme
   - Run on iPhone simulator (iOS 18.5+)
   - Add some favorite docks in the app

2. **Add Widget to Home Screen**
   - Stop the app
   - Long-press on simulator home screen
   - Tap "+" button in top-left
   - Search for "BikeSpot London"
   - Select widget and choose size (Small, Medium, or Large)
   - Tap "Add Widget"

3. **Test Widget Updates**
   - Run the app again
   - Add/remove favorites or update data
   - Widget should update automatically
   - May need to wait a few seconds for updates

4. **Test Deep Linking**
   - Tap on a widget
   - App should open to the Favorites screen
   - Small widget should navigate to specific dock

### On Device

1. **Select a Development Team**
   - Both "BikeSpot London" and "BikeSpot London Widget" targets need signing
   - Select your development team in Signing & Capabilities

2. **Build and Run**
   - Connect iPhone running iOS 18.5+
   - Build and run on device
   - Follow same testing steps as simulator

## Troubleshooting

### Widget Not Appearing

- **Check target membership**: Ensure all widget files have "BikeSpot London Widget" target checked
- **Check app group**: Verify both main app and widget have the same app group enabled
- **Rebuild**: Clean build folder (Cmd+Shift+K) and rebuild

### Widget Not Updating

- **Check UserDefaults**: Widget reads from app group UserDefaults with key `ios_widget_data`
- **Force reload**: Call `WidgetCenter.shared.reloadAllTimelines()` (already integrated in FavoritesService)
- **Check console logs**: Look for "WidgetService:" messages in console

### Widget Showing Empty State

- **Add favorites**: Widget only shows data when favorites exist in main app
- **Check data sync**: Verify `WidgetService.updateWidgetData()` is being called (added to HomeViewModel)
- **Check app group access**: Ensure widget can read from shared UserDefaults

### Build Errors

- **Missing imports**: Ensure `import WidgetKit` is present in widget files
- **Shared file conflicts**: If you get duplicate symbol errors, check that shared files are only added to necessary targets
- **Swift version**: Ensure both targets use Swift 5

### Deep Linking Not Working

- **URL scheme**: Verify `myborisbikes://` URL scheme is registered in app Info.plist
- **Check implementation**: Ensure `onOpenURL` handler is present in `BikeSpot_LondonApp.swift`

## Widget Update Flow

```
User adds/removes favorite
         ↓
FavoritesService.saveFavorites()
         ↓
WidgetCenter.shared.reloadAllTimelines() [in FavoritesService]
         ↓
App refreshes data (every 30s)
         ↓
HomeViewModel receives updated BikePoint data
         ↓
HomeViewModel.updateWidgetData()
         ↓
WidgetService.updateWidgetData()
         ↓
Saves to App Group UserDefaults (key: "ios_widget_data")
         ↓
WidgetCenter.shared.reloadAllTimelines() [in WidgetService]
         ↓
Widget Timeline Provider loads data
         ↓
Widget UI updates
```

## Data Structure

The widget reads `WidgetData` from UserDefaults:

```swift
{
  "bikePoints": [
    {
      "id": "BikePoints_123",
      "displayName": "Hyde Park Corner",
      "standardBikes": 5,
      "eBikes": 3,
      "emptySpaces": 12,
      "distance": 250.5,  // meters, optional
      "lastUpdated": "2026-02-02T12:34:56Z"
    },
    // ... more docks
  ],
  "sortMode": "distance",  // or "alphabetical", "manual"
  "lastRefresh": "2026-02-02T12:34:56Z"
}
```

## Performance Considerations

- **Timeline refresh**: Widget refreshes every 5 minutes automatically
- **Data size**: Only favorites are included (not all 800+ bike points)
- **Sorting**: Performed on main app side, widget just displays
- **Memory**: Widget uses simplified models to minimize memory footprint

## Future Enhancements

Potential improvements:

1. **Multiple widget types**: Add alternate widget designs (e.g., map view widget)
2. **Widget configuration**: Let users choose which favorite to show in small widget
3. **Live Activities**: Show real-time updates during a bike ride
4. **Complications**: Apple Watch complications for watchOS widgets
5. **App Intents**: Interactive widgets that can toggle favorites without opening app (iOS 17+)

## Color Scheme

The widget uses the same colors as the main app:

- **Standard bikes**: RGB(236, 0, 0) - Red
- **E-bikes**: RGB(12, 17, 177) - Blue
- **Empty spaces**: RGB(117, 117, 117) - Gray

## Support

For issues or questions about the widget implementation, check:

1. Console logs for "WidgetService:" messages
2. App group UserDefaults content
3. Widget timeline provider logs
4. Xcode Organizer for crash logs

---

## Summary

This widget implementation provides:
- ✅ Multiple widget sizes (Small, Medium, Large)
- ✅ Real-time data synchronization
- ✅ Distance-based sorting with location services
- ✅ Deep linking to app
- ✅ Beautiful donut chart visualizations
- ✅ Automatic updates every 5 minutes
- ✅ App group data sharing
- ✅ Empty state handling

The widget is production-ready and follows iOS design guidelines and best practices.
