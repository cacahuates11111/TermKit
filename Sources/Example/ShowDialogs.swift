//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 3/22/21.
//

import Foundation
import TermKit

func FileDialogs () -> Window {
    let w = Window ()
    w.fill (percentage: 80)
    w.allowClose = true
    
    let open = Button ("Open Dialog") {
        Application.present(top: OpenDialog (title: "Sample Open", message: "Pick a file to open"))
    }
    open.set (x: 1, y: 1)
    
    let save = Button ("Save Dialog") {
        Application.present(top: SaveDialog (title: "Sample Save", message: "Going to save your file"))
    }
    save.set (x: 1, y: 2)
    
    let quit = Button ("Quit") { Application.requestStop() }
    quit.set (x: 1, y: 3)
    
    w.addSubviews([open, save, quit])
    return w
}
