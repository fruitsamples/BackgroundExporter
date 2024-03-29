/*
	File:        MyController.m
	
	Description: Controller class for our MovieExportClient app.
    
	Author:      QuickTime DTS

	Copyright:   � Copyright 2004 Apple Computer, Inc. All rights reserved.
	
	Disclaimer: IMPORTANT: This Apple software is supplied to you by Apple Computer, Inc. ("Apple") in 
                consideration of your agreement to the following terms, and your use, installation, modification 
                or redistribution of this Apple software constitutes acceptance of these terms.  If you do 
                not agree with these terms, please do not use, install, modify or redistribute this Apple software.

                In consideration of your agreement to abide by the following terms, and subject to these terms, 
                Apple grants you a personal, non-exclusive license, under Apple's copyrights in this 
                original Apple software (the "Apple Software"), to use, reproduce, modify and redistribute the 
                Apple Software, with or without modifications, in source and/or binary forms; provided that if you 
                redistribute the Apple Software in its entirety and without modifications, you must retain this 
                notice and the following text and disclaimers in all such redistributions of the Apple Software. 
                Neither the name, trademarks, service marks or logos of Apple Computer, Inc. may be used to 
                endorse or promote products derived from the Apple Software without specific prior written 
                permission from Apple.  Except as expressly stated in this notice, no other rights or 
                licenses, express or implied, are granted by Apple herein, including but not limited to any 
                patent rights that may be infringed by your derivative works or by other works in which the 
                Apple Software may be incorporated.

                The Apple Software is provided by Apple on an "AS IS" basis.  APPLE MAKES NO WARRANTIES, EXPRESS OR 
                IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY 
                AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE 
                OR IN COMBINATION WITH YOUR PRODUCTS.

                IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL 
                DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS 
                OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, 
                REPRODUCTION, MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER 
                UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN 
                IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
                				
	Change History (most recent first): 07/20/04 initial release
*/

#import "MyController.h"

// current export settings
static QTAtomContainer gExportSettings = 0;

// current number added to the filename 
static UInt8 gFileNameNumber = 1;

// update the TextView in the Window
static void UpdateTextView(MyController *inController, NSString *inMessageString)
{
    int length = 0;
    NSAttributedString *theString;
    NSRange theRange;
    
    MyController *theController = (MyController *)inController;
    if (!theController) return;
    
    theString = [[NSAttributedString alloc] initWithString:inMessageString];
    [[[theController textView] textStorage] appendAttributedString: theString];

    length = [[[inController textView] textStorage] length];
    theRange = NSMakeRange(length, 0);
    
    [[theController textView] scrollRangeToVisible:theRange];
    
    [theString release];
}

// callback to recieve reply messages from the Export Server app
static CFDataRef myProgressPortCallBack(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info)
{
    if (!data) return NULL;
    NSString *messageString = [NSString stringWithCString:CFDataGetBytePtr(data)];
    
    MyController *theController = (MyController *)info;
    if (!theController) return NULL;
    
    if ([messageString isEqualToString:@"open"]) {
        [[theController progressControl] startAnimation:theController];
        UpdateTextView(info, @"Request started.\n\n");
    } else if ([messageString isEqualToString:@"close"]) {
        [[theController progressControl] stopAnimation:theController];
        UpdateTextView(info, @"\nRequest done.\n\n");
    } else {
        UpdateTextView(info, messageString);
    }
     
    return NULL;
}

// send a request to Export Server app
static OSErr SendDataToRemotePort(MyController *inController, CFDataRef inData)
{
    CFMessagePortRef remote = CFMessagePortCreateRemote(kCFAllocatorDefault, CFSTR("TheMessagePort"));
    CFDataRef replyData;
    
    OSErr err = paramErr;
    
    if (!remote || !inData) return err;
    
    UpdateTextView(inController, @"Request sent...\n");
    if (kCFMessagePortSuccess == (err = CFMessagePortSendRequest(remote, 0, inData, 1, 1, kCFRunLoopDefaultMode, &replyData))) {
        
        UpdateTextView(inController, [NSString stringWithCString:CFDataGetBytePtr(replyData)]);
        CFRelease(replyData);

        err = noErr;
    }

    CFRelease(inData);
    CFRelease(remote);
    
    return err;
}

@implementation MyController

- (void)awakeFromNib
{    
    [[myMovieView window] setDefaultButtonCell:[myOpenButton cell]];
    [myExportButton setEnabled:NO];
    [myCancelButton setEnabled:NO];
}

- (IBAction)openMovie:(id)sender
{
    NSArray *fileTypes = [NSArray arrayWithObjects:@"mov", nil];
  
    NSOpenPanel *oPanel = [NSOpenPanel openPanel];

    int result = [oPanel runModalForTypes:fileTypes];
    
    if (result == NSOKButton) {
        NSArray *movieToOpen = [oPanel URLs];
        NSURL *movieURL = [movieToOpen objectAtIndex:0];

        // create an NSMovie autoreleased so we can easily pass ownership to NSMovieView
        NSMovie *movie = [[[NSMovie alloc] initWithURL:movieURL byReference:NO] autorelease];
        
        // set the window title appropriately
        UserData userData = GetMovieUserData([movie QTMovie]);
        Handle theName = NewHandle(0);
        GetUserDataText(userData,theName, kUserDataTextFullName, 1, langEnglish);
        if (GetHandleSize(theName) > 0) {
            [[myMovieView window] setTitle:[NSString stringWithCString:(char *)*theName length:GetHandleSize(theName)]];
        } else {
            [[myMovieView window] setTitle:[[movieURL path] lastPathComponent]];
        }
        DisposeHandle(theName);
            
        [myMovieView showController:YES adjustingSize:NO];
        [myMovieView setMovie:movie];
        [myMovieView setNeedsDisplay:YES];
        MCDoAction([myMovieView movieController], mcActionSetKeysEnabled, (void *)false);
        
        // create an FSRef for the source
        OSErr err = FSPathMakeRef([[movieURL path] fileSystemRepresentation], &sourceRef, NULL);
        if (err) { [self doAlert:[NSString stringWithFormat:@"Error %d, could not create FSRef for %@.", err, [movieURL path]]]; return; }
            
        [[myMovieView window] setDefaultButtonCell:[myExportButton cell]];
        [myExportButton setEnabled:YES];
        [myCancelButton setEnabled:YES];
    }
}

// send an export request to the Export Server app
// ask for user settings and bundle everything
// up in a CFData object which is sent via a CFMessagePort
- (IBAction)sendExportRequest:(id)sender
{
    NSSavePanel *sPanel = [NSSavePanel savePanel];
    NSString *theFileName, *errorString;
    MovieExportDataRef pMovieExportData = NULL;
    QTAtomContainer settings = 0;
    OSErr err = noErr;
    
    [sPanel setTitle:@"Export Movie As:"];
    [sPanel setRequiredFileType:@"mov"];

    // don't do anything unless we actually want to export something
    if ([sPanel runModalForDirectory:nil file:[NSString stringWithFormat:@"untitled%d", gFileNameNumber++]] == NSFileHandlingPanelCancelButton) return;
        
    theFileName = [sPanel filename];
        
    // check to see if the file exists and if not, create it
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:theFileName]) {
        if (![fm createFileAtPath:theFileName contents:nil attributes:nil]) {
            err = fnfErr;
            errorString = [NSString stringWithFormat:@"Could not create file at path %@.", theFileName] ; goto bail;
        }
    }
    
    // create an FSRef for the destination
    err = FSPathMakeRef([theFileName fileSystemRepresentation], &destRef, NULL);
    if (err) { errorString = [NSString stringWithFormat:@"Error %d, could not create FSRef for %@.", err, theFileName]; goto bail; }
    
    // open the QuickTime Movie Export component and do that thing
    ComponentInstance ci = OpenDefaultComponent(MovieExportType, kQTFileTypeMovie);
    if (ci) {
        Boolean canceled;
        CFDataRef theData;
        
        // first time though, set up some default settings
        if (NULL == gExportSettings) {
            SCSpatialSettings ss;
            SCTemporalSettings ts;
            UInt8 falseSetting = false;
            QTAtom videAtom = 0;
            QTAtom sptlAtom = 0;
            QTAtom tprlAtom = 0;
            QTAtom saveAtom = 0;
            QTAtom fastAtom = 0;

            ss.codecType = kDVCNTSCCodecType;
            ss.codec = NULL;
            ss.depth = 0;
            ss.spatialQuality = codecHighQuality;
            
            ts.temporalQuality = 0;
            ts.frameRate = 30L<<16;
            ts.keyFrameRate = 0;
            
            // get the defaults and changed 'em
            err = MovieExportGetSettingsAsAtomContainer(ci, &gExportSettings);
            if (err) { errorString = [NSString stringWithFormat:@"Error %d calling MovieExportGetSettingsAsAtomContainer.", err]; goto bail; }
            
            // video options
            videAtom = QTFindChildByID(gExportSettings, kParentAtomIsContainer, kQTSettingsVideo, 1, NULL);
            if (videAtom) {
                // spatial
                sptlAtom = QTFindChildByID(gExportSettings, videAtom, scSpatialSettingsType, 1, NULL);
                if (sptlAtom) {
                    err = QTSetAtomData(gExportSettings, sptlAtom, sizeof(SCSpatialSettings), &ss);
                }
                // temporal
                tprlAtom = QTFindChildByID(gExportSettings, videAtom, scTemporalSettingsType, 1, NULL);
                if (tprlAtom) {
                    err = QTSetAtomData(gExportSettings, tprlAtom, sizeof(SCTemporalSettings), &ts);
                }
            }
                
            // turn off save for internet options aka fastStart
            saveAtom = QTFindChildByID(gExportSettings, kParentAtomIsContainer, kQTSettingsMovieExportSaveOptions, 1, NULL);
            if (saveAtom) {
                fastAtom = QTFindChildByID(gExportSettings, saveAtom, kQTSettingsMovieExportSaveForInternet, 1, NULL);
                if (fastAtom) {
                    err = QTSetAtomData(gExportSettings, fastAtom, sizeof(falseSetting), &falseSetting);
                }
            }
        }
        
        // set 'em
        err = MovieExportSetSettingsFromAtomContainer(ci, gExportSettings);
        if (err) { errorString = [NSString stringWithFormat:@"Error %d calling MovieExportSetSettingsFromAtomContainer.", err]; goto bail; }
        
        // now ask the user - obviously you don't need to do this if some type of batch processing is required
        err = MovieExportDoUserDialog(ci, [[myMovieView movie] QTMovie], NULL, 0, GetMovieDuration([[myMovieView movie] QTMovie]), &canceled);
        if (err) { errorString = [NSString stringWithFormat:@"Error %d calling MovieExportDoUserDialog.", err]; goto bail; }
        if (canceled) {
            // delete the newly created file because we're not really doing anything
            if (![fm removeFileAtPath:theFileName handler:nil]) {
                err = fnfErr;
                errorString = [NSString stringWithFormat:@"Could not remove file at path %@.", theFileName]; goto bail;
            }
            
            goto bail;
        }
        
        // get 'em for the export request
        err = MovieExportGetSettingsAsAtomContainer(ci, &settings);
        if (err) { errorString = [NSString stringWithFormat:@"Error %d calling MovieExportGetSettingsAsAtomContainer.", err]; goto bail; }
        
        // get 'em for next time, toss what we have first so we don't leak
        QTDisposeAtomContainer(gExportSettings);
        MovieExportGetSettingsAsAtomContainer(ci, &gExportSettings);
        
        pMovieExportData = (MovieExportDataRef)malloc(GetHandleSize(settings) + sizeof(MovieExportData));
        if (NULL == pMovieExportData) { errorString = @"malloc failed, sweeeet!"; goto bail; } 
        
        pMovieExportData->requestType = kExportRequest;
        pMovieExportData->sourceRef = sourceRef;
        pMovieExportData->destRef = destRef;
        pMovieExportData->componentType = MovieExportType;
        pMovieExportData->componentSubType = kQTFileTypeMovie;
        pMovieExportData->exportSettingsSize = GetHandleSize(settings);
        memcpy(pMovieExportData->exportSettings, *settings, pMovieExportData->exportSettingsSize);
        
        theData = CFDataCreate(kCFAllocatorDefault, (UInt8 *)pMovieExportData, pMovieExportData->exportSettingsSize + sizeof(MovieExportData));
        if (NULL == theData) { errorString = @"Could not create CFData for Export request, time to go get a beer!"; goto bail; }

        err = SendDataToRemotePort(self, theData);
        if (err) { errorString = [NSString stringWithFormat:@"Error %d sending Export data to remote message port.", err]; goto bail; }
    }

bail:
    if (ci) CloseComponent(ci);
    if (pMovieExportData) free(pMovieExportData);
    if (settings) QTDisposeAtomContainer(settings);
    if (err) [self doAlert:errorString];
}

// send a request to cancel the last export request
- (IBAction)sendCancelRequest:(id)sender
{
    CFDataRef theData;
    UInt8     theRequest = kCancelRequest;
    
    // send a cancel message to the export worker app
    theData = CFDataCreate(kCFAllocatorDefault, &theRequest, sizeof(theRequest));
    if (NULL == theData) { [self doAlert:@"Could not create CFData for request!"]; return; }
    
    OSErr err = SendDataToRemotePort(self, theData);
    if (err) { [self doAlert:[NSString stringWithFormat:@"Error %d sending Cancel request to remote message port.", err]]; return; }
}

#pragma mark **** Getters ****
- (NSTextView *)textView
{
    return myTextView;
}

- (NSProgressIndicator *)progressControl
{
    return myProgressControl;
}

#pragma mark **** Utility ****
// ***** utility methods

// display an alert sheet and log any errors
- (void)alertDidEnd:(NSAlert *)alert returnCode:(int)returnCode contextInfo:(void *)contextInfo
{
    [[alert window] orderOut:self];
}

- (void)doAlert:(NSString *)inString
{
    NSAlert *theAlert = [NSAlert alertWithMessageText:nil
                                 defaultButton:nil
                                 alternateButton:nil
                                 otherButton:nil
                                 informativeTextWithFormat:inString];
 
    [theAlert beginSheetModalForWindow:[myMovieView window]
                                      modalDelegate:self
                                      didEndSelector:@selector(alertDidEnd:returnCode:contextInfo:)
                                      contextInfo:(void *)nil];
    NSLog(inString);
}

#pragma mark **** Delegates ****
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication
{
    return YES;
}

#pragma mark **** Notifications ****
// create an in memory movie with a single text track, this will be the inital Movie
// seen in the MovieView - also launch the background Export Server application
- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    Track theTrack;
    Media theMedia;
    MediaHandler theHandler;
    Handle dataRef = NULL;
    
    CFMessagePortContext contextInfo = { 0 };
    
    // allocate a local port for the progress messages
    contextInfo.info = self;
    localPort = CFMessagePortCreateLocal(kCFAllocatorDefault, CFSTR("TheProgressPort"), myProgressPortCallBack, &contextInfo, false);
    CFRunLoopSourceRef source = CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, localPort, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes /*kCFRunLoopDefaultMode*/);
    
    // create an in memory text movie to be displayed initially
    
    // allocate memory for the text sample data
    hMovieData = NewHandle(0);
    
    // construct the Handle data reference
    PtrToHand(&hMovieData, &dataRef, sizeof(Handle));
    
    // create the new movie, track and media
    textMovie = NewMovie(newMovieActive);
    theTrack = NewMovieTrack(textMovie, FixRatio(320, 1), FixRatio(240, 1), kNoVolume);
    theMedia = NewTrackMedia(theTrack, TextMediaType, 600, dataRef, HandleDataHandlerSubType);
    theHandler = GetMediaHandler(theMedia);
    
    // add the media sample
    if (noErr == BeginMediaEdits(theMedia)) {
        Str255 theTextSample = "\pSelect Movie to Export";
        Rect theBounds = { 0, 0, 240, 320 };
        RGBColor myTextColor = {0xFFFF, 0xFFFF, 0xFFFF};
        RGBColor myBackColor = {0x0000, 0x0000, 0x0000};
        
        InsetRect(&theBounds, 0, 110);
        
        TextMediaAddTextSample(theHandler, (Ptr)(&theTextSample[1]), theTextSample[0],
                                kFontIDTimes, 24, 0, &myTextColor, &myBackColor, teCenter,
                                &theBounds, dfAntiAlias | dfShrinkTextBoxToFit,
                                0, 0, 0, NULL, 600, NULL);

        EndMediaEdits(theMedia);
        
        InsertMediaIntoTrack(theTrack, 0, 0, 1, fixed1);
    }
    
    // turn it into an NSMovie for the view
    NSMovie *movie = [[NSMovie alloc] initWithMovie:textMovie];
    [myMovieView showController:NO adjustingSize:NO];
    [myMovieView setMovie:movie];
    [myMovieView setNeedsDisplay:YES];
    MCDoAction([myMovieView movieController], mcActionSetKeysEnabled, (void *)false);
    
    // toss the dataRef it's no longer needed
    DisposeHandle(dataRef);

// if you want to debug the server by itself just turn off this code
// and use MovieExportServer.xcode
#if (1)
    // launch the export server - if this fails there's no point in going on
    CFBundleRef mainBundleRef = CFBundleGetMainBundle();
    CFURLRef executableURL = CFBundleCopyAuxiliaryExecutableURL(mainBundleRef, CFSTR("MovieExportServer"));
	LSLaunchURLSpec inLaunchSpec = { executableURL,
									 NULL, NULL, kLSLaunchDontSwitch | kLSLaunchDefaults, NULL };
	
	OSStatus err = LSOpenFromURLSpec(&inLaunchSpec, NULL);
    
    if (err) {
        NSLog(@"Error %d launching export server, no point going on from here eh?", err);
        ExitToShell();
    }
    
    CFRelease(mainBundleRef);
    CFRelease(executableURL);
#endif

}  

// we're quitting so tell the Export Server to quit as well
- (void)applicationWillTerminate:(NSNotification *)aNotification
{
    UInt8 theRequest = kShutdownRequest;
    
    // send a quit message to the export worker app
    CFDataRef theData = CFDataCreate(kCFAllocatorDefault, &theRequest, sizeof(theRequest));
    if (NULL == theData) { NSLog(@"Could not create CFData for Quit!"); return; }
    
    OSErr err = SendDataToRemotePort(self, theData);
    if (err) { NSLog([NSString stringWithFormat:@"Error %d sending Quit request to remote message port.", err]); }

    DisposeHandle(hMovieData);
}

@end