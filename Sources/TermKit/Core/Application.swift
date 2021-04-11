//
//  Application.swift - Application initialization and main loop.,
//  MiniGui
//
//  Created by Miguel de Icaza on 3/6/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//

import Foundation
import Darwin.ncurses
import os

var fd: Int32 = -1
@available(OSX 11.0, *)
var logger: Logger = Logger(subsystem: "termkit", category: "TermKit")

public func log (_ s: String)
{
    if #available(macOS 11.0, *) {
        logger.log("log: \(s, privacy: .public)")
        return
    }
    if fd == -1 {
        fd = open ("/tmp/log", O_CREAT | O_RDWR, S_IRWXU)
    }
    let data = (s + "\n").data(using: String.Encoding.utf8)!
    let _ = data.withUnsafeBytes { (dataBytes: UnsafeRawBufferPointer) -> Int in
        return write(fd, dataBytes.baseAddress, data.count)
    }
}

class SizeError : Error {
}

enum ApplicationError : Error {
    case internalState(msg:String)
}

/**
 * The `Application` class is responsible for running your application.
 *
 * The `Application` class has at least one `TopLevel` view that is displayed (and
 * is the one pointed to by `top`) and will send events to this instance.   You
 * should add your views to this top instance.   A minimal initialization sequence
 * looks like this:
 *
 * ```
 * Application.prepare ()
 * let win = Window()
 * win.fill ()
 * Application.top.addSubview (win)
 * Application.run()
 * ```
 *
 * The call to the `prepare` method initializes the default console driver, which will
 * be set depending on your platform and heuristics (currently it is limited to the
 * curses version).
 *
 * Then you need to add one or more views to your application, in the example above,
 * a new `Window` is created, we flag it to take over all the available space by calling
 * the `fill` method, and then we add this to the `top` element.   Once this happens,
 * we call `Application.run` which is a method that will never return.
 *
 * # TopLevels
 * At any given point there is only a single `Toplevel` instance active, this means that
 * all mouse and keyboard events are routed here.   There might be multiple visible `Toplevel`
 * at any given point, for example the main application is a `Toplevel`, and a popup dialog
 * box is another form of a toplevel.   When the popup is executing, all keyboard and mouse
 * input are routed to the dialog box, but the main Toplevel will still be updated visually
 * and might also be updated continously.
 *
 * To execute a new nested toplevel, one that either obscures a portion of the screen, or the
 * whole screen, you call the `run` method with the new instance.   To pop the toplevel from
 * the stack, you call the `Application.requestStop` method which will queue the toplevel for
 * termination and will make the previous toplevel the active one.
 *
 * # Main Loop Execution
 * Calling the `run` method in `Application` will start the mainloop, which is implemented using
 * the Dispatch framework.   This means that this method will never return, but also that all
 * the operations that you have come to expect from using the Dispatch API (from Grand Central Dispatch)
 * will work as expected.
 *
 * The TermKit framework is not multi-thread safe, so any operations that you execute on the background
 * should queue operations that access properties, or call methods in any of the TermKit methods
 * using the global queue, so that the operation is executed in the context of the TermKit queue.
 *
 */
public class Application {
    /// Points to the global application
    static var _top : Toplevel? = nil
    static var _current : Toplevel? = nil
    static var toplevels : [Toplevel] = []
    static var debugDrawBounds : Bool = false
    static var initialized: Bool = false
    
    /// The Toplevel object used for the application on startup.
    public static var top : Toplevel {
        get {
            guard let x = _top else {
                print ("You must call Application.prepare()")
                abort()
            }
            return x
        }
    }
    
    /// The current toplevel object.   This is updated when Application.Run enters and leaves and points to the current toplevel.
    public static var current : Toplevel? {
        get {
            return _current
        }
    }

    /// The current Console Driver in use.
    static var driver : ConsoleDriver = CursesDriver()
    
    /**
     * Prepares the application, must be called before anything else.
     */
    public static func prepare ()
    {
        if initialized {
            return
        }
        let _ = driver
        toplevels = []
        _current = nil
        _top = Toplevel()
        wantContinuousButtonPressedView = nil
        lastMouseOwnerView = nil
        initialized = true
        rootMouseHandlers = [:]
        lastMouseToken = 0
        let _ = driver
        log ("Columns/rows: \(driver.cols) \(driver.rows)")
    }
    
    /**
     * Triggers a refresh of the whole display
     */
    static public func refresh ()
    {
        // This will be re-enabled later, but could just reuse our layers system at this point
        // no need to redraw anymore - a redraw system still has debugging value, so maybe
        // a different method, or a debug flag?
        updateDisplay(compose ())
        driver.refresh()
//        
//        driver.updateScreen ()
//        var last : View? = nil
//        for v in toplevels {
//            v.setNeedsDisplay()
//            v.redraw(region: v.bounds, painter: Painter.createRootPainter (from: v))
//            last = v
//        }
//        last?.positionCursor()
//        driver.refresh()
    }
    
    static func processKeyEvent (event : KeyEvent)
    {
        defer {
            if Application.initialized {
                postProcessEvent()
            }
        }
        log ("processKeyEvent: \(event)")
        let toplevelCopy = toplevels.reversed()
        for top in toplevelCopy {
            if top.processHotKey(event: event) {
                return
            }
            if top.modal {
                break
            }
        }
        
        for top in toplevelCopy {
            if top.processKey(event: event) {
                return
            }
            if top.modal {
                break
            }
        }
        
        for top in toplevelCopy {
            if top.processColdKey(event: event) {
                return
            }
            if top.modal {
                break
            }
        }
    }
    
    static func findDeepestView (start : View, x: Int, y: Int) -> (view: View, resx: Int, resy: Int)?
    {
        let startFrame = start.frame
        
        if !startFrame.contains(Point (x: x, y: y)){
            return nil
        }

        let count = start.subviews.count
        if count > 0 {
            let location = Point(x: x - startFrame.minX, y: y - startFrame.minY)
            for i in (0..<(count)).reversed() {
                let v = start.subviews[i]
                if v.frame.contains(location) {
                    let deep = findDeepestView(start: v, x: location.x, y: location.y)
                    if deep == nil {
                        return (view: v, resx: 0, resy: 0)
                    }
                    return deep
                }
            }
        }

        return (view: start, resx: x-startFrame.minX, resy: y-startFrame.minY)
    }
    
    // Tracks the view that has grabbed the mouse
    static var mouseGrabView: View? = nil
    
    /// Grabs the mouse, forcing all mouse events to be routed to the specified view until `ungrabMouse` is called.
    /// - Parameter from: View that will receive all mouse events until UngrabMouse is invoked.
    public static func grabMouse (from view: View)
    {
        mouseGrabView = view
        driver.uncookMouse ()
    }

    /// Ungrabs the mouse, allowing mouse events that were previously captured by one view to flow to other views
    public static func ungrabMouse ()
    {
        mouseGrabView = nil
        driver.cookMouse ()
    }
    
    static var wantContinuousButtonPressedView: View? = nil
    static var lastMouseOwnerView: View? = nil

    static var rootMouseHandlers : [Int:(MouseEvent)->()] = [:]
    static var lastMouseToken = 0
    
    /**
     * A token representing a registered root mouse handler
     */
    public struct MouseHandlerToken {
        var token: Int
    }
    
    /**
     * Registers a global mouse event handler to be invoked for every mouse event, this
     * is called before any event processing takes place for the currently focused view.
     */
    public static func addRootMouseHandler (_ handler : @escaping (MouseEvent)->()) -> MouseHandlerToken
    {
        let ret = lastMouseToken
        rootMouseHandlers [lastMouseToken] = handler
        lastMouseToken += 1
        return MouseHandlerToken (token: ret)
    }
    
    /**
     * Removes a previously registered mouse event handler
     */
    public static func removeRootMouseHandler (_ token: MouseHandlerToken)
    {
        rootMouseHandlers.removeValue(forKey: token.token)
    }
    
    static func outsideFrame (_ p: Point, _ r: Rect) -> Bool {
        return p.x < 0 || p.x > r.width-1 || p.y < 0 || p.y > r.height - 1
    }
    
    static func processMouseEvent (mouseEvent: MouseEvent)
    {
        for h in rootMouseHandlers.values {
            h (mouseEvent)
        }
        guard let c = _current else {
            return
        }
        
        let res = findDeepestView(start: c, x: mouseEvent.x, y: mouseEvent.y)
        defer { postProcessEvent() }
        
        if let r = res {
            if r.view.wantContinuousButtonPressed {
                wantContinuousButtonPressedView = r.view
            } else {
                wantContinuousButtonPressedView = nil
            }
            if let grab = mouseGrabView {
                let newxy = grab.screenToView(x: mouseEvent.x, y: mouseEvent.y)
                let nme = MouseEvent(x: newxy.x, y: newxy.y, absX: mouseEvent.x, absY: mouseEvent.y, flags: mouseEvent.flags, view: r.view)
                if outsideFrame(Point (x: nme.x, y: nme.y), grab.frame) {
                    let _ = lastMouseOwnerView?.mouseLeave(event: mouseEvent)
                }
                let _ = grab.mouseEvent(event: nme)
                return
            }
            
            let nme = MouseEvent(x: r.resx, y: r.resy, absX: mouseEvent.x, absY: mouseEvent.y, flags: mouseEvent.flags, view: r.view)
            if lastMouseOwnerView == nil {
                lastMouseOwnerView = r.view
                let _ = r.view.mouseEnter(event: nme)
            } else if lastMouseOwnerView != r.view {
                let _ = lastMouseOwnerView?.mouseLeave(event: nme)
                let _ = r.view.mouseEnter(event: nme)
                lastMouseOwnerView = r.view
            }
            if !r.view.wantMousePositionReports && (mouseEvent.flags == MouseFlags.mousePosition) {
                return
            }
            wantContinuousButtonPressedView = r.view.wantContinuousButtonPressed ? r.view : nil
            
            // Should we bubble up the event if it not handled?
            let _ = r.view.mouseEvent (event: nme)
        } else {
            wantContinuousButtonPressedView = nil
        }
        
    }
    
    static func compose () -> [Cell]
    {
        let screenSize = Size (width: Application.driver.cols, height: Application.driver.rows)
        var screen = Toplevel.allocateLayer (attr: Colors.base.normal, size: screenSize)
        for x in 0..<screen.count {
            screen [x].ch = "x"
        }
        let screenFrame = Rect (origin: Point (x: 0, y: 0), size: screenSize)
        for view in toplevels {
            let vframe = view.frame
            
            let intersection = screenFrame.intersection (vframe)
            if intersection == Rect.zero {
                continue
            }
            
            // the source location to copy from (clamped)
            let sourceStart = Point (x: vframe.minX < 0 ? -vframe.minX : 0, y: vframe.minY < 0 ? -vframe.minY : 0)
            for row in 0..<intersection.height {
                let y = intersection.minY + row
                
                // the offset into the array
                let targetOffset = y * screenSize.width + intersection.minX
                let sourceOffset = (sourceStart.y + row) * vframe.width + sourceStart.x
                screen.replaceSubrange(targetOffset..<(targetOffset + intersection.width), with: view.backingStore [sourceOffset..<sourceOffset+intersection.width])
            }
            updateDisplay(screen, Application.driver.cols, Application.driver.rows)
        }
        return screen
    }
    
    static func updateDisplay (_ buffer: [Cell]) {
        updateDisplay(buffer, Application.driver.cols, Application.driver.rows)
    }
    
    static func updateDisplay (_ buffer: [Cell], _ cols: Int, _ rows: Int) {
        var attr: Int32 = -1
        var idx = 0
        (Application.driver as? CursesDriver)!.sync = true
        for y in 0..<rows {
            driver.moveTo(col: 0, row: y)
            
            for x in 0..<cols {
                let cell = buffer [idx]
                idx += 1
                attr = -1
                if cell.attr.value != attr {
                    attr = cell.attr.value
                    driver.setAttribute(cell.attr)
                }
                driver.addCharacter(cell.ch)
            }
        }
        driver.updateScreen()
    }
    
    /**
     * Building block API: Prepares the provided toplevel for execution.
     *
     * This method prepares the provided toplevel for running with the focus,
     * it adds this to the list of toplevels, sets up the mainloop to process the
     * event, lays out the subviews, focuses the first element, and draws the
     * toplevel in the screen.   This is usually followed by executing
     * the `RunLoop` method, and then the `End(RunState` method upon termination which
     * will undo these changes
     *
     * - Parameter toplevel: Toplevel to prepare execution for.
     * - Returns: The runstate handle that needs to be passed to the `end` method upon completion
     */
    public static func begin (toplevel: Toplevel)
    {
        if !initialized {
            print ("You should call Application.prepare() to initialize")
            abort ()
        }
        toplevels.append(toplevel)
        _current = toplevel
        if toplevel.layoutStyle == .computed {
            toplevel.relativeLayout(hostFrame: Rect(x: 0, y: 0, width: driver.cols, height: driver.rows))
        }
        do {
            try toplevel.layoutSubviews()
        } catch {}
        toplevel.willPresent()
        toplevel.paintToBackingStore ()
        let content = compose()
        updateDisplay(content)
        //redrawView (toplevel)
        toplevel.positionCursor()
        driver.refresh()
    }

    /**
     * Makes the provided toplevel the new toplevel, sending all events to it,
     * it returns control immediately.   If the toplevel is modal 
     */
    public static func present (top: Toplevel)
    {
        begin (toplevel: top);
    }
    
    /**
     * Starts the application mainloop - does not return, but can exit to the OS.
     */
    public static func run ()
    {
        begin (toplevel: top)
        dispatchMain()
    }
    
    static func redrawView (_ view: View)
    {
        abort ()
        let painter = Painter.createRootPainter (from: view)
        view.redraw(region: view.bounds, painter: painter)
        driver.refresh()
    }
    
    // Called by RunState when it disposes
    static func end (_ top: Toplevel) throws
    {
        if toplevels.last == nil {
            throw ApplicationError.internalState(msg: "The current toplevel is null, and the end callback is being called")
        }
        if toplevels.last! != top {
            throw ApplicationError.internalState(msg: "The current toplevel is not the one that this is being called on")
        }
        toplevels = toplevels.dropLast ()
        if toplevels.count == 0 {
            Application.shutdown ()
        } else {
            _current = toplevels.last as Toplevel?
            refresh ()
        }
    }
    
    // This is currently a hack invoked after any input events have been processed
    // and triggers the redisplay of information.   The way that this should work
    // instead is that setNeedsLayout, and setNeedsDisplay should queue an operation
    // if they are invoked, to trigger this processing.
    //
    // This would have a couple of benefits: one, it would allow more than one character
    // to be processed on input, rather than refreshing for each character, and later would
    // help me split the frame processing like UIKit does: input first, layout next,
    // redraw next, driver.refresh last.
    //
    // So this hack is here just temporarily
    static func postProcessEvent ()
    {
        if let c = current {
            if c.layoutNeeded {
                try? c.layoutSubviews()
                c.setNeedsDisplay()
            }
            if !c.needDisplay.isEmpty || c._childNeedsDisplay {
                c.redraw (region: c.bounds, painter: Painter.createTopPainter(from: c))
                updateDisplay(compose ())
//                if debugDrawBounds {
//                    drawBounds (c)
//                }
                c.positionCursor()
                driver.refresh()
            } else {
                c.positionCursor()
                driver.updateCursor()
            }
        }
    }
    
//    static func drawBounds (_ view: View)
//    {
//        view.drawFrame(view.frame, padding: 0, fill: false)
//        for childView in view.subviews {
//            drawBounds(childView)
//        }
//    }
    
    /**
     * Stops running the most recent toplevel, use this to close a dialog, window, or toplevel.
     * The last time this is called, it will return to the OS and will return with the status code 0.
     *
     * If you want to terminate the application with a different status code, call the `Application.shutdown`
     * method directly with the desired exit code.
     */
    public static func requestStop ()
    {
        DispatchQueue.global ().async {
            if let c = current {
                c._running = false
                
                toplevels = toplevels.dropLast ()
                if toplevels.count == 0 {
                    Application.shutdown ()
                } else {
                    _current = toplevels.last as Toplevel?
                    refresh ()
                }
            } else {
                Application.shutdown()
            }
        }
    }
    
    static func terminalResized ()
    {
        let full = Rect(x: 0, y: 0, width: driver.cols, height: driver.rows)
        driver.clip = full
        for top in toplevels {
            top.relativeLayout(hostFrame: full)
            do {
                try top.layoutSubviews()
            } catch {}
        }
        refresh ()
    }
    
    /**
     * Terminates the application execution
     *
     * Because this is using Dispatch to run the application main loop, there is no way of terminating
     * the main loop, other than exiting the process.   This restores the terminal to its previous
     * state and terminates the process.
     *
     * - Paramter statusCode: status code passed to the `exit(2)` system call to terminate the process.
     */
    public static func shutdown(statusCode: Int = 0)
    {
        for top in toplevels {
            top._running = false
        }
        initialized = false
        driver.end ();
        exit (Int32 (statusCode))
    }
}

