import { StrictMode, lazy, Suspense } from 'react'
import { createRoot } from 'react-dom/client'
import {
  createRootRoute,
  createRoute,
  createRouter,
  Outlet,
  redirect,
  RouterProvider,
} from '@tanstack/react-router'
import '@fontsource-variable/geist'
import '@fontsource-variable/geist-mono'
import './index.css'
import { api, setCsrf } from './api'
import { AppToaster, Loading } from './components'

const Login = lazy(() => import('./pages/login').then((m) => ({ default: m.Login })))
const Dashboard = lazy(() => import('./pages/dashboard').then((m) => ({ default: m.Dashboard })))
const Providers = lazy(() => import('./pages/providers').then((m) => ({ default: m.Providers })))
const RouterPage = lazy(() => import('./pages/router').then((m) => ({ default: m.RouterPage })))
const Keys = lazy(() => import('./pages/keys').then((m) => ({ default: m.Keys })))
const Logs = lazy(() => import('./pages/logs').then((m) => ({ default: m.Logs })))
const Audit = lazy(() => import('./pages/audit').then((m) => ({ default: m.Audit })))

const rootRoute = createRootRoute({
  component: () => (
    <Suspense fallback={<Loading />}>
      <Outlet />
      <AppToaster />
    </Suspense>
  ),
})

// Outside the auth guard: minimal layout, no chrome.
const loginRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/login',
  component: Login,
})

// Auth guard: verify the session (and pick up the CSRF token) before
// any console route renders.
const authLayout = createRoute({
  getParentRoute: () => rootRoute,
  id: '_auth',
  beforeLoad: async () => {
    try {
      const s = await api('/session')
      if (s?.csrf) setCsrf(s.csrf)
    } catch {
      throw redirect({ to: '/login' })
    }
  },
  component: () => <Outlet />,
})

const indexRoute = createRoute({ getParentRoute: () => authLayout, path: '/', component: Dashboard })
const providersRoute = createRoute({ getParentRoute: () => authLayout, path: '/providers', component: Providers })
const routerRoute = createRoute({ getParentRoute: () => authLayout, path: '/router', component: RouterPage })
const modelsRoute = createRoute({
  getParentRoute: () => authLayout,
  path: '/models',
  beforeLoad: () => {
    throw redirect({ to: '/router' })
  },
})
const keysRoute = createRoute({ getParentRoute: () => authLayout, path: '/keys', component: Keys })
const logsRoute = createRoute({ getParentRoute: () => authLayout, path: '/logs', component: Logs })
const auditRoute = createRoute({ getParentRoute: () => authLayout, path: '/audit', component: Audit })

const routeTree = rootRoute.addChildren([
  loginRoute,
  authLayout.addChildren([indexRoute, providersRoute, routerRoute, modelsRoute, keysRoute, logsRoute, auditRoute]),
])

const router = createRouter({ routeTree, basepath: '/' })

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router
  }
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <RouterProvider router={router} />
  </StrictMode>,
)
